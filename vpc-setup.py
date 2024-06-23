#!/usr/bin/python3 -u

from __future__ import print_function
import sys
import os
import boto3
from ec2_metadata import ec2_metadata
import re
import argparse
import subprocess
import ipaddress

# Collect inputs and assign to variables
parser = argparse.ArgumentParser()
parser.add_argument('--account_id', required=True, help="AWS Account ID. A 12-digit number including leading zeros. Example: 006828683766")
parser.add_argument('--name', required=True, help="Name of VPC to build in Consumer Account")
parser.add_argument('--region', required=True, help="Region of new VPC in Consumer Account")
parser.add_argument('--ip_allocation', required=True, help="The IP allocation size.")
parser.add_argument('--manual_cidr', required=True, help="Force this script to use this specific CIDR instead of finding a free one. Otherwise, specify 'no'.")
parser.add_argument('--transit', required=True, help="Does the VPC need transit connectivity to the FICO network (for database replication for instance)? Valid values: yes|no")
parser.add_argument('--ss_peering', required=True, help="Does the VPC need peering to the shared services environment? Valid values: yes|no")

args = parser.parse_args()
account_id = args.account_id
vpc_name = args.name
base_region = args.region
ip_allocation = args.ip_allocation
transit = args.transit
peering = args.ss_peering
manual_cidr = args.manual_cidr

# If we aren't running in an expected location then get out
if ec2_metadata.region != 'us-west-2' and ec2_metadata.region != 'eu-west-1':
    exit("This script is designed to be run in AWS Cloud Management regions only (US-WEST-2 and EU-WEST-1)")

# Verify the account ID matches the regular expression before making the DynamoDB API call
account_id_re = re.compile(r"^\d{12}$")
if not account_id_re.match(account_id):
    exit("Malformed AWS Account ID. Please verify and try again.")

master_sess = boto3.session.Session()
dynamodb_client = master_sess.client('dynamodb', ec2_metadata.region)
response = dynamodb_client.get_item(
    TableName='account_mapping',
    Key={'account_id': {'S': account_id}}
)
if 'Item' not in response:
    exit("Unable to find Account ID in the mapping table. Please verify the ID or raise a ticket with AWS Cloud Services.")
else:
    account_name = response['Item']['account_name']['S']
    account_type = response['Item']['account_type']['S']

if account_type == 'sandbox':
    exit("VPCs in sandbox accounts are not created via this process, but directly within the AWS console.")

# Validation
config_map = {"production-pci": "prod-pci", "production": "prod", "nonproduction-customer": "prod", "internal": "nonprod"}
ss_map = {"production-pci": "prod-pci", "production": "prod", "nonproduction-customer": "prod", "internal": "nonprod"}

# Base region - check it matches allowed/supported regions, including environment checks
region_re = re.compile(r"^(us|ap|sa|eu|ca)\-(east|west|northeast|southeast|south|central)\-[1-3]$")
if not region_re.match(base_region):
    exit("Your region looks invalid.")

# Only check the mapping table if peering or transit is required
if peering == 'yes' or transit == 'yes':
    config_options = "{0}-{1}".format(config_map[account_type], base_region)
    response = dynamodb_client.get_item(
        TableName='vpc_mapping',
        Key={'config_options': {'S': config_options}}
    )
    if 'Item' not in response:
        exit("Unable to find region details in the mapping table. Please verify the availability of the region in the same environment as the requesting account or raise a ticket with AWS Cloud Services.")

# IP allocation - check it's a suitable size
ip_re = re.compile(r"^/[1-2][0-9]$")
if not ip_re.match(ip_allocation):
    exit("Your IP Allocation looks invalid (should be /18 - /28).")

# Transit - check it's a yes/no
if transit != 'yes' and transit != 'no':
    exit("You must specify yes or no for the transit connectivity.")

# Peering - check it's a yes/no
if peering != 'yes' and peering != 'no':
    exit("You must specify yes or no for the peering connectivity")

# Find account dir. Exit if it doesn't exist.
account_dir_b = subprocess.check_output("find /opt/terraform/accounts/prod | grep " + account_id + " | head -1", shell=True).strip()
account_dir = account_dir_b.decode('ascii')
if account_dir == "":
    raise Exception("The account " + account_id + " has no existing account source directory.")

# VPC name - check it doesn't already exist
vpc_name = vpc_name.replace(" ", "_")
vd = "{0}/environment_regional_{1}".format(account_dir, base_region.replace("-", "_"))
vf = "{0}/environment_regional_{1}/vpc_{2}.tf".format(account_dir, base_region.replace("-", "_"), vpc_name.lower())

if os.path.exists(vd) and os.path.exists(vf):
    raise Exception("A VPC with the given name already exists within the account. VPC names must be unique.")

# Print it out to the user to confirm
print("Determined the following settings : ")
print("Account ID              : ", account_id)
print("Account Name            : ", account_name)
print("Account Type            : ", account_type)
print("Account Dir             : ", account_dir)
print("Region                  : ", base_region)
print("IP Allocation           : ", ip_allocation)
print("Transit Connectivity    : ", transit)
print("Shared Services Peering : ", peering)
print("")

# Define function for CIDR slicing
def cidr_slicing(ip_block, netmask):
    availablenetwork = ipaddress.IPv4Network(ip_block)
    prefixlen = availablenetwork.prefixlen
    prefixlen_diff = netmask - prefixlen
    sliced2_network_fulllist = []
    i = 1
    while i <= prefixlen_diff:
        sliced2_network = list(availablenetwork.subnets(new_prefix=prefixlen + i))
        sliced2_network_fulllist.append(sliced2_network[0].compressed)
        availablenetwork = sliced2_network[-1]
        if i == prefixlen_diff:
            sliced2_network_fulllist.append(availablenetwork.compressed)
        i = i + 1
    network_list = sliced2_network_fulllist
    return network_list

# If CIDR is not manually provided, determine what's available in DynamoDB based on size
if manual_cidr == "no":
    print("Fetching available IP Block...")
    # Assign an (appropriately sized) free IP block (based on the defined region)
    response = dynamodb_client.scan(
        TableName='ip_allocations',
        FilterExpression='#size = :size and availability = :availability and #region = :region',
        ExpressionAttributeNames={
            '#region': 'region',
            '#size': 'size'
        },
        ExpressionAttributeValues={
            ":size": {"S": ip_allocation},
            ":availability": {"S": "available"},
            ":region": {"S": base_region}
        }
    )
    netmask = int(ip_allocation.strip('/'))
    while response['Count'] == 0:
        print("Unable to locate an exact CIDR block to allocate to the account. Checking for next closest CIDR...")
        netmask -= 1
        ip_allocation_new = '/' + str(netmask)
        print("Checking " + ip_allocation_new)
        if netmask < 16:
            exit("Not able to find an appropriately sized CIDR in the region. Please consult Cloud Services DevSecOps")

        response = dynamodb_client.scan(
            TableName='ip_allocations',
            FilterExpression='#size = :size and availability = :availability and #region = :region',
            ExpressionAttributeNames={
                '#region': 'region',
                '#size': 'size'
            },
            ExpressionAttributeValues={
                ":size": {"S": '/' + str(netmask)},
                ":availability": {"S": "available"},
                ":region": {"S": base_region}
            }
        )
    config_options = "{0}-{1}".format(config_map[account_type], base_region)
    CIDR = response['Items'][0]
    ip_block = CIDR['cidr']['S']
    netmask = int(ip_allocation.strip('/'))
    if ip_allocation in ip_block:
        print("Netmask matches, slicing not required.")
        print("IP Block assigned : " + ip_block)
        response = dynamodb_client.update_item(
            TableName='ip_allocations',
            Key={'cidr': {'S': ip_block}},
            UpdateExpression="SET availability = :availability, account_id = :account_id, config_options = :config_options",
            ExpressionAttributeValues={
                ":availability": {"S": "in-use"},
                ":account_id": {"S": account_id},
                ":config_options": {"S": config_options}
            }
        )
        new_cidr = ip_block
    else:
        network_list = cidr_slicing(ip_block, netmask)
        print("IP Block assigned : " + network_list[-2])
        # Adding CIDR slices to DynamoDB table
        for network in network_list:
            print("Adding " + network + " to DynamoDB")
            response = dynamodb_client.update_item(
                TableName='ip_allocations',
                Key={'cidr': {'S': network}},
                UpdateExpression="SET #size = :size, availability = :availability, #region = :region",
                ExpressionAttributeNames={
                    '#region': 'region',
                    '#size': 'size'
                },
                ExpressionAttributeValues={
                    ":availability": {"S": "available"},
                    ":region": {"S": base_region},
                    ":size": {"S": network[-3:]}
                }
            )
        # Updating allocated CIDR to 'in-use'
        print("Updating " + network_list[-2] + " to in-use")
        response = dynamodb_client.update_item(
            TableName='ip_allocations',
            Key={'cidr': {'S': network_list[-2]}},
            UpdateExpression="SET #size = :size, availability = :availability, account_id = :account_id, #region = :base_region, config_options = :config_options",
            ExpressionAttributeNames={
                '#region': 'region',
                '#size': 'size'
            },
            ExpressionAttributeValues={
                ":availability": {"S": "in-use"},
                ":account_id": {"S": account_id},
                ":base_region": {"S": base_region},
                ":config_options": {"S": config_options},
                ":size": {"S": network_list[-2][-3:]}
            }
        )
        new_cidr = network_list[-2]
        # Remove original CIDR which got sliced
        print("Removing " + ip_block)
        response = dynamodb_client.delete_item(
            TableName='ip_allocations',
            Key={'cidr': {'S': ip_block}},
            ReturnValues='ALL_OLD'
        )

# If manual CIDR is entered, don't bother slicing and skip right to updating the table
if manual_cidr != "no":
    ip_block = manual_cidr
    print("Using manually specified CIDR:  " + ip_block)
    new_cidr = ip_block
    config_options = "{0}-{1}".format(config_map[account_type], base_region)
    print("Updating " + ip_block + " to in-use")
    response = dynamodb_client.update_item(
        TableName='ip_allocations',
        Key={'cidr': {'S': ip_block}},
        UpdateExpression="SET #size = :size, availability = :availability, account_id = :account_id, #region = :base_region, config_options = :config_options",
        ExpressionAttributeNames={
            '#region': 'region',
            '#size': 'size'
        },
        ExpressionAttributeValues={
            ":availability": {"S": "in-use"},
            ":account_id": {"S": account_id},
            ":base_region": {"S": base_region},
            ":config_options": {"S": config_options},
            ":size": {"S": ip_allocation}
        }
    )

# Generate the necessary Terraform source to create the VPC in the consumer account
# If the directory doesn't exist yet then we need to create that also and put some basic files in there
print("")
print("{0:60}".format('Checking Environment Regional Directory'), end='')
if os.path.exists(vd) == False:
    os.mkdir(vd)
    os.symlink("../provider.tf", vd + "/provider.tf")
    variables_def = """variable region {{ default = "{region}" }}"""
    var_file = open(vd + "/variables.tf", "w")
    var_file.write(variables_def.format(region=base_region))
    var_file.close()
    os.symlink("/opt/terraform/templates/shared/core_services/prod/remote_state.tf", vd + "/remote_state.tf")
    os.symlink("/opt/terraform/templates/shared/core_services/prod/environment_regional/variables.tf", vd + "/variables_template.tf")

    print("[Created]")
else:
    print("[Skipped]")

# Maybe also needs account_regional setup for the region?
print("{0:60}".format('Checking Account Regional Directory'), end='')
ard = "{0}/account_regional_{1}".format(account_dir, base_region.replace("-", "_"))
if os.path.exists(ard) == False:
    os.mkdir(ard)
    os.symlink("/opt/terraform/templates/shared/core_services/prod/remote_state.tf", ard + "/remote_state.tf")
    os.symlink("/opt/terraform/templates/shared/core_services/prod/regional/account_regional.tf", ard + "/account_regional.tf")
    os.symlink("/opt/terraform/templates/shared/core_services/prod/regional/variables.tf", ard + "/variables_template.tf")
    os.symlink("../provider.tf", ard + "/provider.tf")
    var_def = """variable region {{ default = "{region}" }}"""
    var_file = open(ard + "/variables.tf", "w")
    var_file.write(var_def.format(region=base_region) + '\n')
    var_file.write('variable environment { default = "" }\n')
    var_file.write('variable account-id { default = "" }\n')
    var_file.write('variable account-type { default = "" }\n')
    var_file.write('variable exec-session-token {}\n')
    var_file.write('variable exec-region {}\n')
    var_file.write('variable exec-environment {}\n')
    var_file.write('variable exec-access-key {}\n')
    var_file.write('variable exec-secret-key {}\n')
    var_file.close()
    with open("/tmp/account_regional_dir", "w") as cfg_file:
        cfg_file.write(ard)
        cfg_file.close()
    print("[Created]")
else:
    with open("/tmp/account_regional_dir", "w") as cfg_file:
        cfg_file.write("")
        cfg_file.close()
    print("[Skipped]")

print("{0:60}".format('Generating Terraform Code'), end='')
need_transit = ""
if transit == 'yes':
    need_transit = "vpc_transit          = true"

peering_string = ""
if peering == "yes":
    peering_string = "vpc_peering          = \"1\"\n"
    response = dynamodb_client.get_item(TableName='vpc_mapping', Key={'config_options': {'S': config_options}})
    if 'Item' not in response:
        raise Exception("Unable to find Account ID in the mapping table. Please verify the ID or raise a ticket with AWS Cloud Services.")
    else:
        gts_bootstrap_zone_id = response['Item']['gts_bootstrap_zone_id']['S']
        with open("/tmp/gts_bootstrap_zone_id", "w") as cfg_file:
            cfg_file.write(gts_bootstrap_zone_id)
            cfg_file.close()
        ss_env_vpc_id = response['Item']['vpc_id']['S']
        with open("/tmp/ss_env_vpc_id", "w") as cfg_file:
            cfg_file.write(ss_env_vpc_id)
            cfg_file.close()
else:
    with open("/tmp/gts_bootstrap_zone_id", "w") as cfg_file:
        cfg_file.write("")
        cfg_file.close()

vpc_def = """
resource "aws_vpc" "client_{name_lower}" {{
  cidr_block = "{new_cidr}"
  # Both of these are needed to support private route 53 zones
  assign_generated_ipv6_cidr_block = false
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = {{
    "Name"  = "{name}-{env}"
  }}
}}

module "common_{name_lower}" {{
  source               = "/opt/terraform/modules/shared/core_services/prod/environment_regional/vpc"
  vpc_id               = aws_vpc.client_{name_lower}.id
  {need_transit}
  region               = var.region
  main_route_table_id  = aws_vpc.client_{name_lower}.main_route_table_id
  environment          = "{env}"
  {peering_string}
  segment              = "{env}"
  service              = ""
  test_env_prefix      = ""
  cfg_data_region      = "us-west-2"
  exec-access-key      = var.exec-access-key
  exec-secret-key      = var.exec-secret-key
  exec-session-token   = var.exec-session-token
  business_service_tag = local.business_service
  owner_tag            = local.owner
  customer_tag         = local.customer
  usage_tag            = "{env}"
  product_tag          = local.product
}}
"""

vpc_file = open(vf, "w")
vpc_file.write(vpc_def.format(name_lower=vpc_name.lower(), name=vpc_name, env=config_map[account_type].upper(), new_cidr=new_cidr, peering_string=peering_string, need_transit=need_transit, region=base_region))
vpc_file.close()
print("[Created]")

# Write VPC config data to disk to be used later by further steps in this process
with open("/tmp/account_dir", "w") as cfg_file:
    cfg_file.write(account_dir)
    cfg_file.close()
with open("/tmp/account_type", "w") as cfg_file:
    cfg_file.write(account_type)
    cfg_file.close()
with open("/tmp/account_dir", "w") as cfg_file:
    cfg_file.write(account_dir)
    cfg_file.close()
with open("/tmp/vpc_module_name", "w") as cfg_file:
    cfg_file.write("client_" + vpc_name.lower())
    cfg_file.close()
with open("/tmp/vpc_cidr", "w") as cfg_file:
    cfg_file.write(new_cidr)
    cfg_file.close()
