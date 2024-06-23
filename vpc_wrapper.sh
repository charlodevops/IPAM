#!/bin/bash

# This wrapper script is used to manage the VPC creation process in a consumer account. It called by the following Jenkins job:
#
# https://cse-jenkins.aws.com/job/AWS/job/Infrastructure/job/VPC_Create_New_SS/configure
#
# This Jenkins job sets the following environment variables which are leveraged by this script:
#
# AWS_ACCOUNT_ID:       ID of AWS Account to where new VPC will be created.  A 12-digit number including leading zeros.  Example = 006828683766.
# VPC_NAME:             Name of VPC to build in Consumer Account.  Alphanumeric characters, hyphens, and underscores ONLY.
# REGION:               AWS region name
# IP_ALLOCATION:        Size of CIDR block for VPC.  Valid values:  /26 | /25 | /24 | /23 | /22
# USE_EXISTING_CIDR:    Would you like to force this script to use a CIDR instead of choosing one.  If not, set to 'no'.  If yes, specify the CIDR.
# TRANSIT_CONNECTIVITY: 'yes' | 'no'
# SS_PEERING:           'yes' | 'no'
# SNOW_CHG_RECORD:      The approved SNOW Change Record for this action (if applicable).
# MERGE_TO_MASTER:      'yes' | 'no' - Automatically merge the generated hotfix branch to the 'master' branch in Bitbucket and destroy the hotfix branch.

# Quick sanity check on a few arguments.  The Python scripts called further below do further checking.
if [ ${#AWS_ACCOUNT_ID} != 12 ]; then
  echo -e "\nFATAL ERROR: Account ID $AWS_ACCOUNT_ID is not 12 characters in length.\n"
fi
if [[ "${VPC_NAME}" =~ [^a-zA-Z0-9\_\-] ]]; then
  echo -e "\nFATAL ERROR: VPC name $VPC_NAME contains illegal characters.  Only alphanumeric, hyphens, or underscores are allowed.\n"
fi 

echo -e "\n*************************************************************************************************************"
echo "Info for New SS Terraform worker node:"
hostname
hostname -i
echo -e "\nSNOW CHANGE RECORD: ${SNOW_CHG_RECORD}"

terraform_root="/opt/terraform"
current_dir=$(pwd)
sudo rm -rf $terraform_root
sudo ln -s $current_dir/shared_services_core $terraform_root
rm -rf `find . -type d -name ".terraform"`
cd /opt/terraform

echo -e "\nGit user configuration:"
git config --global user.name $BUILD_USER
git config --global user.email $BUILD_USER
git config --global -l

# Make the 'accounts' directory in the separate 'consumers' repo also available under /opt/terraform
sudo ln -s $current_dir/shared_services_consumers/accounts $terraform_root/accounts
cd /opt/terraform/accounts
git config --local remote.origin.url "https://git-bitbucket.aws.fico.com:8443/scm/cloud/shared_services_consumers.git"

# Make the sharedservices test and prod account directories available with all of the other consumer accounts in /opt/terraform/accounts
sudo ln -s $current_dir/shared_services_core_cfg/accounts/prod/production-pci/sharedservices.031087784557 $terraform_root/accounts/prod/production-pci/sharedservices.031087784557
cd /opt/terraform/accounts/prod/production-pci/sharedservices.031087784557
git config --local remote.origin.url "https://git-bitbucket.aws.fico.com:8443/scm/cloud/shared_services_core_cfg.git"
umask 002
mkdir -p $terraform_root/accounts/test/internal
sudo ln -s $current_dir/shared_services_core_cfg/accounts/test/internal/sharedservices.008743059065 $terraform_root/accounts/test/internal/sharedservices.008743059065
cd /opt/terraform/accounts/test/internal/sharedservices.008743059065
git config --local remote.origin.url "https://git-bitbucket.aws.fico.com:8443/scm/cloud/shared_services_core_cfg.git"

# Make the 'shared/core_services' dir from the 'shared_services_core_scripts" repo available as /opt/terraform/scripts/shared/core_services
mkdir -p $terraform_root/scripts
sudo ln -s $current_dir/shared_services_core_scripts/shared $terraform_root/scripts/shared

# Place a copy of the terraform wrapper from the shared_services_core_scripts repo in ~/.local/bin/terraform
echo -e "\nInstalling Terraform wrapper script from scripts repo to ~/.local/bin/terraform\n"
TF_BIN="/home/ec2-user/.local/bin/terraform"
rm -f ${TF_BIN}
cp -f $current_dir/shared_services_core_scripts/shared/core_services/terraform ${TF_BIN}

# Install any necessary python 3 modules 
umask 002
pip3 install ec2_metadata --user
sudo chmod -R 755 /usr/local/lib/python3.7/site-packages/*

# Execute VPC creation script to determine and/or reserve CIDR block and generate required Terraform source for consumer account dir
if ! $current_dir/shared_services_core_scripts/core_services/aws_account_and_vpc/vpc_setup.py --account_id ${AWS_ACCOUNT_ID} --name ${VPC_NAME} \
--region ${REGION} --ip_allocation ${IP_ALLOCATION} --transit ${TRANSIT_CONNECTIVITY} --ss_peering ${SS_PEERING} --manual_cidr ${USE_EXISTING_CIDR}; then
  echo -e "\nFATAL ERROR: VPC Configuration failed.\n"
  exit 1
else
  ACCOUNT_FULL_DIR=$(find /opt/terraform/accounts/ | grep ${AWS_ACCOUNT_ID} | head -1)
  ACCOUNT_DIR=$(echo ${ACCOUNT_FULL_DIR} | awk -F '/' '{print $NF}')
  REGION_U=$(echo ${REGION} | sed 's/-/_/g')
  REGIONAL_DIR="${ACCOUNT_FULL_DIR}/environment_regional_${REGION_U}"
  if [ ! -d "$REGIONAL_DIR" ]; then
    mkdir -p $REGIONAL_DIR
  fi
  cd $REGIONAL_DIR
  echo -e "\nWorking directory: $REGIONAL_DIR"
  
  # Since we had success generating the code, commit it to Bitbucket on a hotfix branch
  CONSUMER_GIT_BRANCH="hotfix/new_vpc_${VPC_NAME}_${AWS_ACCOUNT_ID}_${REGION}"
  echo -e "\nCommitting new TF code to branch ${CONSUMER_GIT_BRANCH} in 'shared_services_consumers' repo ..."
  
  # Make sure this branch doesn't already exist in the origin repo
  BRANCH_EXIST=$(git branch -a | grep remotes/origin/${CONSUMER_GIT_BRANCH})
  if [ "${BRANCH_EXIST}" != "" ]; then
    echo -e "\nFATAL ERROR: Branch ${CONSUMER_GIT_BRANCH} already exists in remote git repo 'shared_services_consumers'."
    echo -e "You must delete that branch first.\n"
    exit 1
  fi
  if ! git checkout -b ${CONSUMER_GIT_BRANCH} origin/master; then
    echo -e "\nFATAL ERROR: Could not successfully create new branch ${CONSUMER_GIT_BRANCH} from origin/master branch."
    echo -e "It's possible the origin/master branch already contains source files for this VPC you are attempting to create."
    echo -e "Check if that's the case, and if so, you'll need to delete those source files from that branch so that this"
    echo -e "automation can re-create them.\n"
    exit 1
  fi
  git add ../account_regional_${REGION_U}/*.tf
  git add *.tf
  git commit -m "Added new VPC code for VPC ${VPC_NAME} in account ${AWS_ACCOUNT_ID} in region ${REGION}"
  REMOTE_URL=$(git config -l | grep remote.origin.url | awk -F'=' '{print $2}' | awk -F'://' '{print $2}')
  if ! git push "https://${GIT_USER}:${GIT_TOKEN}@${REMOTE_URL}" --all; then
    echo -e "\nFATAL ERROR: Push of new Terraform code to Bitbucket on remote branch ${CONSUMER_GIT_BRANCH} failed."
    echo -e "CIDR Block for new VPC has been reserved in DynamoDB and an SSM parameter created in config_data in the region."
    exit 1
  fi
  
  # Now attempt to apply the new Terraform source to create the resources from the consumer account dir
  echo -e "\nDeploying resources with Terraform ..."
  echo -e "\nInitializing Terraform ..."
  ${TF_BIN} init -no-color > tf_init_results.log
  if ! grep -q "Terraform has been successfully initialized!" tf_init_results.log; then
    echo -e "\nFATAL ERROR: Terraform INIT failed."
    echo -e "CIDR Block for new VPC has been reserved in DynamoDB and an SSM parameter created in config_data in the region."
    echo -e "Refer to newly created branch ${CONSUMER_GIT_BRANCH} in git repo 'shared_services_consumers' to debug the generated code."
    echo -e "If you want to try this process again from the beginning, you'll need to remove the DynamoDB entry, SSM parameter,"
    echo -e "and git hotfix branch.\n"
    exit 1
  fi
  # Because of a race condition that cannot be solved in code, we must create just the VPC first
  # and then we can create the remaining resources
  VPC_RESOURCE_NAME=$(cat /tmp/vpc_module_name)
  TF_CMD="${TF_BIN} apply -no-color --auto-approve -target=aws_vpc.${VPC_RESOURCE_NAME}"
  echo -e "\nExecuting Terraform command: $TF_CMD\n"
  ${TF_CMD} | tee tf_apply_results.log
  if ! grep -q "Apply complete!" tf_apply_results.log; then
    echo -e "\nFATAL ERROR: Terraform APPLY failed."
    echo -e "CIDR Block for new VPC has been reserved in DynamoDB and an SSM parameter created in config_data in the region."
    echo -e "Refer to newly created branch ${CONSUMER_GIT_BRANCH} in git repo 'shared_services_consumers' to debug the generated code."
    echo -e "If you want to try this process again from the beginning, you'll need to remove the DynamoDB entry, SSM parameter,"
    echo -e "and git hotfix branch.\n"
    exit 1
  fi
  # If an old SSM record for the CIDR still exists, import it to avoid a Terraform apply failure in the next step
  echo -e "\nAttempting to import a legacy SSM CIDR record if it already exists.  If the 'terraform import' fails, it's perfectly okay...\n"
  VPC_MODULE_NAME=$(echo ${VPC_RESOURCE_NAME} | sed 's/client_/common_/g')
  VPC_SUBNET=$(cat /tmp/vpc_cidr)
  SSM_CIDR_BLOCK=$(echo ${VPC_SUBNET} | sed 's#/#_#g')
  ${TF_BIN} import module.${VPC_MODULE_NAME}.aws_ssm_parameter.vpc_cidrs_for_ami /config_data/vpc_cidr/${SSM_CIDR_BLOCK}

  TF_CMD="${TF_BIN} apply -no-color --auto-approve"
  echo -e "\n\nExecuting Terraform command: $TF_CMD\n"
  ${TF_CMD} | tee tf_apply_results_2.log
  if ! grep -q "Apply complete!" tf_apply_results_2.log; then
    echo -e "\nFATAL ERROR: Terraform APPLY failed."
    echo -e "CIDR Block for new VPC has been reserved in DynamoDB and an SSM parameter created in config_data in the region."
    echo -e "Refer to newly created branch ${CONSUMER_GIT_BRANCH} in git repo 'shared_services_consumers' to debug the generated code."
    echo -e "If you want to try this process again from the beginning, you'll need to remove the DynamoDB entry, SSM parameter,"
    echo -e "and git hotfix branch.\n"
    exit 1
  fi

  # Get ID of newly created VPC.  
  VPC_ID=$(${TF_BIN} state show aws_vpc.${VPC_RESOURCE_NAME} | grep \"vpc-[0-9] | awk -F '=' '{print $2}' | tr -d '" ')
  if [ "${VPC_ID}" == "" ]; then
    echo -e "\nFATAL ERROR: Unable to get ID of newly created VPC from Terraform state."
    echo -e "This is a partially complete deployment.  The newly generated TF code successfully applied to the environment,"
    echo -e "however the new VPC ID mysteriously cannot be obtained.\n"
    echo -e "Refer to newly created branch ${CONSUMER_GIT_BRANCH} in git repo 'shared_services_consumers' to debug the generated code."
    echo -e "This applied code remains unmerged to the 'master' branch to allow you to debug/repair before merging.  Don't forget to merge!"
    exit 1
  fi
  echo -e "\nSUCCESS: Generated and applied new code for this new VPC!  VPC ID is: $VPC_ID\n"
  
  # If we reached this point, we had complete success, so merge the code from the newly created hotfix branch to the master branch
  # and remove the hotfix branch since it's no longer needed.
  if [ "${MERGE_TO_MASTER}" == "yes" ]; then
    git checkout -b master origin/master
    git merge ${CONSUMER_GIT_BRANCH}
    git push "https://${GIT_USER}:${GIT_TOKEN}@${REMOTE_URL}" --all
    echo -e "\nSUCCESS: Branch ${CONSUMER_GIT_BRANCH} has been merged to the 'master' branch in the 'shared_services_consumers' repo."
    git branch -D ${CONSUMER_GIT_BRANCH}
    git push "https://${GIT_USER}:${GIT_TOKEN}@${REMOTE_URL}" -d ${CONSUMER_GIT_BRANCH}
    echo -e "\nSUCCESS: Branch ${CONSUMER_GIT_BRANCH} has been removed.\n"
  else
    echo -e "\nWARNING:  Hotfix branch ${CONSUMER_GIT_BRANCH} in origin repo 'shared_services_consumers' is NOT merged to 'master'."
    echo -e "WARNING:  Perform this merge as soon as possible as the 'master' branch is not currently in synch with what is deployed.\n"
  fi
fi

# If SS peering was chosen, setup all of the following
if [ "${SS_PEERING}" == "yes" ]; then
  # Fetch additional VPC-related config data created by vpc_setup.py above to pass into the separate scripts
  ACCOUNT_TYPE=$(cat /tmp/account_type)
  if [ "${ACCOUNT_TYPE}" == "internal" ]; then
    ACCT_TYPE_ARG="NONPROD"
    LEGACY_PEERING_ACCT_TYPE="NONPROD"
  elif [ "${ACCOUNT_TYPE}" == "nonproduction-customer" ]; then
    ACCT_TYPE_ARG="NONPROD-CUST"
    LEGACY_PEERING_ACCT_TYPE="NONPROD-CUST"
  elif [ "${ACCOUNT_TYPE}" == "production" ]; then
    ACCT_TYPE_ARG="PROD"
    LEGACY_PEERING_ACCT_TYPE="PROD"
  elif [ "${ACCOUNT_TYPE}" == "production-pci" ]; then
    ACCT_TYPE_ARG="PROD"
    LEGACY_PEERING_ACCT_TYPE="PROD-PCI"
  else
    echo -e "\nFATAL ERROR: Unsupported account type encountered: ${ACCOUNT_TYPE}."
    echo -e "Cannot proceed with generating code for PCX acceptance and return routes in 'shared_services_core' repo.\n"
    exit 1
  fi

  # Execute gts-bootstrap script in Consumer Account dir to associate new consumer VPC to SS 'gts.bootstrap' zone in Route 53
  echo -e "\nExecuting gts-bootstrap script in Consumer Account dir to associate new consumer VPC to SS 'gts.bootstrap' zone in Route 53 ...\n"
  VPC_NAME_LOWER=$(echo "$VPC_NAME" | tr '[:upper:]' '[:lower:]')
  GTS_BOOTSTRAP_ZONE_ID=$(cat /tmp/gts_bootstrap_zone_id)
  if ! $current_dir/shared_services_core_scripts/core_services/aws_account_and_vpc/gts-bootstrap ${GTS_BOOTSTRAP_ZONE_ID} ${REGION} ${VPC_NAME_LOWER}; then
    #echo -e "\nFATAL ERROR: The gts-bootstrap script failed during SS Peering setup."
    #echo -e "This is a partially complete deployment.  This TF worker node will live for 30 minutes for you to debug, or you can create a new worker node.\n"
    #exit 1  
    echo -e "\nWARNING: The gts-bootstrap script failed during SS Peering setup.\n"
  fi

  # Execute ss-route53-sharing script in Consumer Account dir to associate new consumer VPC to SS 'services.aws.fico.com' zone in Route 53
  echo -e "\nExecuting ss-route53-sharing script in Consumer Account dir to associate new consumer VPC to SS 'services.aws.fico.com' zone in Route 53 ...\n"
  SS_ENVIRONMENT_VPC_ID=$(cat /tmp/ss_env_vpc_id)
  SERVICES_ZONE_ID=$(aws route53 list-hosted-zones-by-vpc --vpc-id ${SS_ENVIRONMENT_VPC_ID} --vpc-region ${REGION} | jq -r '.HostedZoneSummaries[] | select(.Name == "services.aws.fico.com.")' | jq -r '.HostedZoneId')
  if ! $current_dir/shared_services_core_scripts/core_services/aws_account_and_vpc/ss-route53-sharing ${SERVICES_ZONE_ID} ${REGION} ${VPC_ID}; then
    #echo -e "\nFATAL ERROR: The ss-route53-sharing script failed during SS Peering setup."
    #echo -e "This is a partially complete deployment.  This TF worker node will live for 30 minutes for you to debug, or you can create a new worker node.\n"
    #exit 1  
    echo -e "\nWARNING: The ss-route53-sharing script failed during SS Peering setup.\n"
  fi

  # Now switch to the 'shared_services_core' repo for the remaining setup in our SS repository
  echo -e "\nGenerating TF code in 'shared_services_core' repo for peering connection acceptance and return routes for new VPC ..."
  cd $current_dir/shared_services_core/modules/core_services/core_services/prod/environment_regional/environment
  git config --local remote.origin.url "https://git-bitbucket.aws.fico.com:8443/scm/cloud/shared_services_core.git"
  git checkout -b ${CONSUMER_GIT_BRANCH} origin/master
  if ! $current_dir/shared_services_core_scripts/core_services/aws_account_and_vpc/consumer_vpc_pcx_setup_in_ss_account.py \
--account_dir ${ACCOUNT_DIR} --account_type ${ACCT_TYPE_ARG} --vpc_name ${VPC_NAME} --vpc_id ${VPC_ID} --vpc_subnets ${VPC_SUBNET} \
--region ${REGION}; then
    echo -e "\nFATAL ERROR: Setup of VPC peering acceptance and return routes to new VPC(s) in SS account failed."
    echo -e "This is a partially completed deployment.\n"
    exit 1
  fi
  
  echo -e "\nGenerating TF code in 'shared_services_core' repo for LEGACY VPC peering connection acceptance and return routes for new VPC ..."
  if ! $current_dir/shared_services_core_scripts/core_services/aws_account_and_vpc/consumer_vpc_legacy_pcx_setup_in_ss_account.py \
--account_dir ${ACCOUNT_DIR} --account_type ${LEGACY_PEERING_ACCT_TYPE} --vpc_name ${VPC_NAME} --vpc_id ${VPC_ID} --vpc_subnets ${VPC_SUBNET} \
--region ${REGION}; then
    echo -e "\nFATAL ERROR: Setup of LEGACY VPC peering acceptance and return routes to new VPC(s) in SS account failed."
    echo -e "This is a partially complete deployment.\n"
    exit 1
  fi

  # Since we had success generating the code, commit it to Bitbucket on a hotfix branch
  echo -e "\nCommitting new TF code to branch ${CONSUMER_GIT_BRANCH} in 'shared_services_core' repo ..."
  git add *.tf
  git commit -m "Added new VPC peering and return route code for VPC ${VPC_NAME} in consumer account ${AWS_ACCOUNT_ID} in region ${REGION}"
  REMOTE_URL=$(git config -l | grep remote.origin.url | awk -F'=' '{print $2}' | awk -F'://' '{print $2}')
  git push "https://${GIT_USER}:${GIT_TOKEN}@${REMOTE_URL}" --all
  echo -e "\nNewly generated code for the new VPC has been committed to branch ${CONSUMER_GIT_BRANCH} in the 'shared_services_core' repo.\n"

  if [ "${ACCOUNT_TYPE}" == "internal" ]; then
    REGIONAL_DIR="/opt/terraform/accounts/prod/production-pci/sharedservices.031087784557/prod_regional_${REGION_U}_development"
  else
    REGIONAL_DIR="/opt/terraform/accounts/prod/production-pci/sharedservices.031087784557/prod_regional_${REGION_U}_production"
  fi
  echo -e "\n\nDeploying resources with Terraform ..."
  echo -e "Working directory: $REGIONAL_DIR"
  cd $REGIONAL_DIR
  echo -e "\nInitializing Terraform ..."
  ${TF_BIN} init -no-color > tf_init_results.log
  if ! grep -q "Terraform has been successfully initialized!" tf_init_results.log; then
    echo -e "\nFATAL ERROR: Terraform INIT failed."
    echo -e "This is a partially complete deployment.  This TF worker node will live for 30 minutes for you to debug.\n"
    exit 1
  fi
  
  TF_CMD="${TF_BIN} apply -no-color --auto-approve"
  echo -e "\nExecuting Terraform command: $TF_CMD\n"
  ${TF_CMD} > tf_apply_results.log
  if ! grep -q "Apply complete!" tf_apply_results.log; then
    echo -e "\nFATAL ERROR: Terraform APPLY in ${REGIONAL_DIR} failed."
    echo -e "This is a partially complete deployment.  To debug, provision a New Shared Services worker node"
    echo -e "with the SERVICE_GIT_BRANCH field set to: ${CONSUMER_GIT_BRANCH}\n"
    exit 1
  fi
  # If this is an 'internal(Development)' account, then we also need to deploy in the 'hybrid VPC' segment
  if [ "${ACCOUNT_TYPE}" == "internal" ]; then
    REGIONAL_DIR="/opt/terraform/accounts/prod/production-pci/sharedservices.031087784557/prod_regional_${REGION_U}_hybrid"
    echo -e "\n\nDeploying resources with Terraform ..."
    echo -e "Working directory: $REGIONAL_DIR"
    cd $REGIONAL_DIR
    echo -e "\nInitializing Terraform ..."
    ${TF_BIN} init -no-color > tf_init_results.log
    if ! grep -q "Terraform has been successfully initialized!" tf_init_results.log; then
      echo -e "\nFATAL ERROR: Terraform INIT failed."
      echo -e "This is a partially complete deployment. To debug, provision a New Shared Services worker node"
      echo -e "with the SERVICE_GIT_BRANCH field set to: ${CONSUMER_GIT_BRANCH}\n"
      exit 1
    fi
    TF_CMD="${TF_BIN} apply -no-color --auto-approve"
    echo -e "\nExecuting Terraform command: $TF_CMD\n"
    ${TF_CMD} > tf_apply_results.log
    if ! grep -q "Apply complete!" tf_apply_results.log; then
      echo -e "\nFATAL ERROR: Terraform APPLY failed."
      echo -e "This is a partially complete deployment. To debug, provision a New Shared Services worker node"
      echo -e "with the SERVICE_GIT_BRANCH field set to: ${CONSUMER_GIT_BRANCH}"
      echo -e "This code remains unmerged to the 'master' branch to allow you to debug/repair before merging.  Don't forget to merge!\n"
      exit 1
    fi
  fi
  echo -e "\nSUCCESS: Generated and applied new code for this new VPC!"
  
  # If we reached this point, we had complete success, so merge the code from the newly created hotfix branch to the master branch
  # and remove the hotfix branch since it's no longer needed.
  if [ "${MERGE_TO_MASTER}" == "yes" ]; then
    cd $current_dir/shared_services_core/modules/core_services/core_services/prod/environment_regional/environment
    git checkout -b master origin/master
    git merge ${CONSUMER_GIT_BRANCH}
    git push "https://${GIT_USER}:${GIT_TOKEN}@${REMOTE_URL}" --all
    echo -e "SUCCESS: Branch ${CONSUMER_GIT_BRANCH} has been merged to the 'master' branch in the 'shared_services_core' repo."
    git branch -D ${CONSUMER_GIT_BRANCH}
    git push "https://${GIT_USER}:${GIT_TOKEN}@${REMOTE_URL}" -d ${CONSUMER_GIT_BRANCH}
    echo -e "SUCCESS: Branch ${CONSUMER_GIT_BRANCH} has been removed.\n"
  else
    echo -e "\nWARNING:  Hotfix branch ${CONSUMER_GIT_BRANCH} in origin repo 'shared_services_core' is NOT merged to 'master'."
    echo -e "WARNING:  Perform this merge as soon as possible as the 'master' branch is not currently in synch with what is deployed.\n"
  fi
fi

# If we created a new 'account_regional_<region>' directory, do these extra steps:
ACCOUNT_REGIONAL_DIR=$(cat /tmp/account_regional_dir)
if [ "${ACCOUNT_REGIONAL_DIR}" != "" ]; then
  echo -e "\nRunning Terraform and additional AWS CLI commmands in newly created account_regional directory ...\n"
  cd ${ACCOUNT_REGIONAL_DIR}
  rm -rf .terraform .terraform.lock.hcl

  ${TF_BIN} init -no-color > tf_init_results.log
  if ! grep -q "Terraform has been successfully initialized!" tf_init_results.log; then
    echo -e "\nFATAL ERROR: Terraform INIT failed in newly generated account_regional directory: ${ACCOUNT_REGIONAL_DIR}"
    echo -e "This is a partially completed deployment.  To debug, provision a New Shared Services Consumer Account worker node"
    echo -e "with the CONSUMER_ACCOUNT_REPO_BRANCH field set to: ${CONSUMER_GIT_BRANCH}\n"
    exit 1
  fi

  echo -e "\nExecuting Terraform command: ${TF_BIN} apply -var='initial_deploy=true' -no-color --auto-approve | tee tf_apply_results.log\n"
  ${TF_BIN} apply -var="initial_deploy=true" -no-color --auto-approve | tee tf_apply_results.log
  if ! grep -q "Apply complete!" tf_apply_results.log; then
    echo -e "\nFATAL ERROR: Terraform APPLY failed in newly generated account_regional directory: ${ACCOUNT_REGIONAL_DIR}"
    echo -e "This is a partially completed deployment.  To debug, provision a New Shared Services Consumer Account worker node"
    echo -e "with the CONSUMER_ACCOUNT_REPO_BRANCH field set to: ${CONSUMER_GIT_BRANCH}\n"
    #This currently does not apply cleanly, but that's okay so don't exit on error
    #exit 1
  fi

  TF_CMD="${TF_BIN} apply -no-color --auto-approve"
  echo -e "\nExecuting Terraform command: $TF_CMD\n"
  ${TF_CMD} > tf_apply_results.log
  if ! grep -q "Apply complete!" tf_apply_results.log; then
    echo -e "\nFATAL ERROR: Final terraform APPLY failed in newly generated account_regional directory: ${ACCOUNT_REGIONAL_DIR}"
    echo -e "This is a partially completed deployment.  To debug, provision a New Shared Services Consumer Account worker node"
    echo -e "with the CONSUMER_ACCOUNT_REPO_BRANCH field set to: ${CONSUMER_GIT_BRANCH}\n"
    #This currently does run successfully, but that's okay so don't exit on error
    #exit 1
  fi
  
  echo -e "\nAdditional setup for newly generated account_regional directory completed successfully!\n"
elif [ "${TRANSIT_CONNECTIVITY}" == "yes" ]; then 
  # If the account_regional directory already existed, we must still do a terraform apply in it if
  # the new VPC used the 'transit' feature which creates a VGW for the VPC because account_regional 
  # wants to build 2 VGW alarms for any VGW in the region in the account.  
  echo -e "\nTransit connectivity was selected so we must run terraform apply in the existing 'account_regional_<region>' directory to build 2 VGW alerts...\n"
  ACCOUNT_REGIONAL_DIR="${ACCOUNT_FULL_DIR}/account_regional_${REGION_U}"
  cd ${ACCOUNT_REGIONAL_DIR}
  rm -rf .terraform .terraform.lock.hcl

  ${TF_BIN} init -no-color > tf_init_results.log
  if ! grep -q "Terraform has been successfully initialized!" tf_init_results.log; then
    echo -e "\nFATAL ERROR: Terraform INIT failed in account_regional directory: ${ACCOUNT_REGIONAL_DIR}"
    echo -e "This is a partially completed deployment.  To debug, provision a New Shared Services Consumer Account worker node"
    echo -e "with the CONSUMER_ACCOUNT_REPO_BRANCH field set to: ${CONSUMER_GIT_BRANCH}\n"
    exit 1
  fi

  echo -e "\nExecuting Terraform command: ${TF_BIN} apply -no-color --auto-approve | tee tf_apply_results.log\n"
  ${TF_BIN} apply -no-color --auto-approve | tee tf_apply_results.log
  if ! grep -q "Apply complete!" tf_apply_results.log; then
    echo -e "\nFATAL ERROR: Terraform APPLY failed in newly generated account_regional directory: ${ACCOUNT_REGIONAL_DIR}"
    echo -e "This is a partially completed deployment.  To debug, provision a New Shared Services Consumer Account worker node"
    echo -e "with the CONSUMER_ACCOUNT_REPO_BRANCH field set to: ${CONSUMER_GIT_BRANCH}\n"
    #This currently does not apply cleanly, but that's okay so don't exit on error
    #exit 1
  fi
  
  # Retrieve config values from SSM parameter store
  BUCKET_NAME=$(aws ssm get-parameter --name /prod/$REGION/core/production/transit_bucket_name | jq -r .Parameter.Value)
  KEY_ID=$(aws ssm get-parameter --name /prod/$REGION/core/production/transit_vpn_key --with-decryption | jq -r .Parameter.Value)

  # Check VPN config bucket policy and add account ID if not already there
  aws s3api get-bucket-policy --bucket $BUCKET_NAME --query Policy --output text > /tmp/bucket_policy.json
  if grep -q $AWS_ACCOUNT_ID /tmp/bucket_policy.json; then
      echo "Account ID already in bucket policy."
  else
      echo "Account ID not in bucket policy.  Adding..."
      sed -i 's/root\"]/root\",\"arn:aws:iam::'$AWS_ACCOUNT_ID':root\"\]/g' /tmp/bucket_policy.json
      aws s3api put-bucket-policy --bucket $BUCKET_NAME --policy file:///tmp/bucket_policy.json
  fi

  # Check KMS key policy and add account ID if not already there
  aws kms get-key-policy --key-id $KEY_ID --region $REGION --policy-name default --output text > /tmp/kms_policy.json
  if grep -q $AWS_ACCOUNT_ID /tmp/kms_policy.json; then
      echo "Account ID already in KMS key policy."
  else
      echo "Account ID not in KMS key policy. Adding..."
      sed -i 's/root\"\ ]/root\", \"arn:aws:iam::'$AWS_ACCOUNT_ID':root\"\ ]/g' /tmp/kms_policy.json
      aws kms put-key-policy --key-id $KEY_ID --region $REGION --policy-name default --policy file:///tmp/kms_policy.json
  fi
  echo "Deploying CloudFormation stack for vgw-poller..."
  # Pull down CloudFormation template file used for Transit VPN deployment
  aws s3 cp s3://"${BUCKET_NAME}"/transit-vpc-"${REGION}".template /tmp/
  # Assume role in consumer account and deploy VGW poller function from CloudFormation template
  # No harm in re-running as CF will only deploy changes needed for the stack
  ASSUME_ROLE="arn:aws:iam::${AWS_ACCOUNT_ID}:role/GTS-AWSEngineering"
  ROLE_SESSION_NAME="terraform"
  CREDENTIALS=$(aws sts assume-role --output json --role-arn ${ASSUME_ROLE} --role-session-name ${ROLE_SESSION_NAME} --region ${REGION})
  export AWS_ACCESS_KEY_ID=$(echo $CREDENTIALS | jq -r ".Credentials.AccessKeyId")
  export AWS_SECRET_ACCESS_KEY=$(echo $CREDENTIALS | jq -r ".Credentials.SecretAccessKey")
  export AWS_SESSION_TOKEN=$(echo $CREDENTIALS | jq -r ".Credentials.SessionToken")
  aws cloudformation deploy --template-file /tmp/transit-vpc-"${REGION}".template --stack-name gts-vgw-poller --capabilities CAPABILITY_NAMED_IAM --region $REGION
fi
