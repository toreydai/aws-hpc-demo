#!/bin/bash

# Copyright (C) 2017 NICE s.r.l.
# Via Milliavacca 9, Asti, AT, 14100, Italy
# All rights reserved.
#
# This software is the confidential and proprietary information
# of NICE s.r.l. ("Confidential Information").
# You shall not disclose such Confidential Information
# and shall use it only in accordance with the terms of
# the license agreement you entered into with NICE.

# This script is executed by CfnCluster on all instances of the cluster
# after everything else, in particular after Chef configures the scheduler.
# There are two goals:
# - install and configure EnginFrame on the master node
# - attach the master node to the ELBV2 Target Group
# - modify the role policy to forbid further access to confidential information (aka password)

# do not remember history
set +o history

# this is used for ansys
touch /home/ubuntu/test.txt
sudo ln -s /lib/x86_64-linux-gnu/libc.so.6 /lib64/libc.so.6
sudo ln -sf /bin/bash /bin/sh
chmod 777 /etc/profile
sudo echo "export PATH=$PATH:/shareEBS/ansys_inc/v193/fluent/bin" >> /etc/profile
source /etc/profile

# this temporary directory will be removed by the following trap even in case of error
declare -r tmpDir=$(mktemp --directory)
trap 'rm -rf "${tmpDir}"' EXIT

# this file is created by CfnCluster
source '/etc/parallelcluster/cfnconfig'

declare -x AWS_DEFAULT_REGION="${cfn_region}"
declare -x AWS_DEFAULT_OUTPUT='text'

declare -r bucket="nice-enginframe-${AWS_DEFAULT_REGION}"
declare -r version="2019.0-r915"

# stdout and stderr of the main function are redirected to /var/log/nice.preinstall.log
main() {

    echo '[info] enginframe.post.sh'

    # these meta-data are always available within an instance, no role/policy required
    local -- macAddress=$(curl -fsq 'http://169.254.169.254/latest/meta-data/mac')
    local -- vpcId=$(curl -fsq "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${macAddress}/vpc-id")
    local -- instanceId=$(curl -fsq 'http://169.254.169.254/latest/meta-data/instance-id')
    local -- roleName=$(curl -fsq 'http://169.254.169.254/latest/meta-data/iam/security-credentials/')

    # this is the stack id of the main CloudFormation stack, the one that was launched at the beginning;
    # keep in mind that script might be executed by an instance launched by hand with cfncluster/cfnconfig
    # so we cannot use the stackId of the "current" cloudformation stack, because it is a different id
    local -r InfrastructureStackId=$(
        aws ec2 describe-vpcs \
            --vpc-ids "${vpcId}" \
            --query 'Vpcs[0].Tags[?Key==`aws:cloudformation:stack-id`].Value'
    )

    # this is the stack id of the current CloudFormation stack launched by CfnCluster
    local -r CfnClusterStackId=$(
        aws cloudformation describe-stacks \
            --stack-name "${stack_name}" \
            --query 'Stacks[0].StackId'
    )

    # this variable stores the json with the description of all resources
    # of the main stack for later use by function getStackResource()
    local -r stackResources=$(
        aws cloudformation --output json \
        describe-stack-resources \
            --stack-name "${InfrastructureStackId}"
    )

    # this variable stores the json with the description of the main stack
    # for later use by function getStackParameter()
    local -r stackDescription=$(
        aws cloudformation --output json \
        describe-stacks \
            --stack-name "${InfrastructureStackId}"
    )

    # name of the primary CloudFormation stack
    local -r InfrastructureStackName=$(
        echo "${stackDescription}" \
        | jq -r '.Stacks[0].StackName'
    )

    # get role ARN
    local -- roleArn=$(
        aws iam get-role \
            --role-name "${roleName}" \
            --query 'Role.Arn'
    )

    # the following steps are executed only on master node instances
    if [[ ${cfn_node_type} == MasterServer ]]; then
        masterConfiguration
    fi

    # these last steps are executed on all instances, both master and compude nodes
    commonConfiguration

    echo '[info] postinstall completed'
}

# this function is executed only on master nodes;
# it installs and configures EnginFrame and Apache;
# it attaches the master instance to the ELBV2 Target Group for this stack
# it also attaches the master instance to the default target group, if this is the very first cfncluster stack
masterConfiguration() {

    echo '[info] masterConfiguration()'

    # install required packages for EnginFrame on the master server
    apt-get install -y --disablerepo epel \
        java-1.8.0-openjdk java-1.8.0-openjdk-devel httpd mod_ssl

    # get root context from stack name with a special case if this is the primary CfnCluster;
    # the possible stack ids in the if expression depends on wether we are using nested or embedded stack
    local -- EF_ROOT_CONTEXT=''
    if [[ ${CfnClusterStackId} == ${InfrastructureStackId} ]]
     then
        EF_ROOT_CONTEXT="${InfrastructureStackName}"
    else
        EF_ROOT_CONTEXT="${stack_name}"
    fi

    # EF configuration parameters
    local -- installer="enginframe-${version}.jar"
    local -x JAVA_HOME='/usr/lib/jvm/java-1.8.0-openjdk'
    local -- NICE_TOP="${cfn_shared_dir}/nice"
    local -- EF_TOP="${NICE_TOP}/enginframe"
    local -- EF_SHARED_ROOT=$(test -d '/efs' && echo "/efs/${EF_ROOT_CONTEXT}" || echo "${EF_TOP}")
    local -- EF_CONF_ROOT="${EF_TOP}/conf"
    local -- EF_TEMP_ROOT="${EF_TOP}/tmp"
    local -- EF_DATA_ROOT="${EF_TOP}/data"
    local -- EF_LOGS_ROOT="${EF_TOP}/logs"
    local -- EF_SPOOLERDIR="${EF_SHARED_ROOT}/spoolers"
    local -- EF_REPOSITORYDIR="${EF_TOP}/repository"
    local -- EF_SESSIONDIR="${EF_TOP}/sessions"
    local -rA schedulerParam=(
        [sge]='sge.profile.file'
        [openlava]='lsf.profile.file'
        [torque]='torque.binaries.path'
        [slurm]='slurm.binaries.path'
    )
    local -rA schedulerValue=(
        [sge]='/opt/sge/default/common/settings.sh'
        [openlava]='/opt/openlava/etc/openlava.sh'
        [torque]='/opt/torque/bin'
        [slurm]='/opt/slurm/bin'
    )
    local -rA efconfig=(
        [efinstall.config.version]='1.0'
        [ef.accept.eula]='true'
        [kernel.eflicense]="${tmpDir}/license.ef"
        [nice.root.dir.ui]="${NICE_TOP}"
        [kernel.java.home]="${JAVA_HOME}"
        [ef.spooler.dir]="${EF_SPOOLERDIR}"
        [ef.repository.dir]="${EF_REPOSITORYDIR}"
        [ef.sessions.dir]="${EF_SESSIONDIR}"
        [ef.data.root.dir]="${EF_DATA_ROOT}"
        [ef.logs.root.dir]="${EF_LOGS_ROOT}"
        [ef.temp.root.dir]="${EF_TEMP_ROOT}"
        [kernel.agent.on.same.machine]='true'
        [kernel.agent.rmi.port]='9999'
        [kernel.agent.rmi.bind.port]='9998'
        [kernel.ef.admin.user]='efadmin'
        [kernel.server.tomcat.https]='false'
        [kernel.ef.tomcat.user]='efnobody'
        [kernel.ef.root.context]="${EF_ROOT_CONTEXT}"
        [kernel.tomcat.port]='8080'
        [kernel.tomcat.shutdown.port]='8005'
        [kernel.ef.db]='derby'
        [kernel.ef.derby.db.port]='1527'
        [kernel.start_enginframe_at_boot]='true'
        [demo.install]='true'
        [default.auth.mgr]='pam'
        [pam.service]='system-auth'
        [ef.jobmanager]="${cfn_scheduler/openlava/lsf}"
        [${schedulerParam[${cfn_scheduler}]}]="${schedulerValue[${cfn_scheduler}]}"
        [ef.delegate.xendesktop]='false'
    )

    # download EF installer and license files from the standard bucket for this AWS region
    echo '[info] downloading EnginFrame...'
    cd "${tmpDir}"
    aws s3 cp "s3://${bucket}/${version}/${installer}" .
    aws s3 cp "s3://${bucket}/${version}/license.ef" .

    # create configuration file for the unattended installation of EnginFrame
    local key; for key in "${!efconfig[@]}"; do
        printf '%s = %s\n' "${key}" "${efconfig[${key}]}" >> 'efinstall.config'
    done

    # quick fix instead of new installer
    mkdir -p "${EF_CONF_ROOT}/tomcat/conf/certs"

    # install EnginFrame
    echo '[info] installing EnginFrame...'
    "${JAVA_HOME}/bin/java" -jar "${installer}" --text --batch -f 'efinstall.config'

    # remove temporary files and log files left by the installer
    rm -f /tmp/enginframe.service.sh /tmp/efinstall.*

    # get the current version string
    unset EF_VERSION; source "${EF_TOP}/current-version"

    # be sure the EF agent always talks with EF Server on the local host, and not through the ELB
    echo "ef.download.server.url=http://127.0.0.1:8080/${EF_ROOT_CONTEXT}/download" \
      >> "${EF_CONF_ROOT}/enginframe/agent.conf"

    # restrict access to port 8080 of Tomcat only to the loopback interface
    sed -i 's|<Connector port="8080"|' \
        "${EF_CONF_ROOT}/tomcat/conf/server.xml"

    # open AJP port of Tomcat, so Apache HTTPD can connect to EnginFrame
    sed -i '/^\s*<!-- Commented out by EnginFrame Installer/!b;N;/<Connector port="8009"/s/.*\n//;T;:a;n;/^\s*-->/!ba;d' \
        "${EF_CONF_ROOT}/tomcat/conf/server.xml"

    # redefine the AJP connector of Tomcat, binding the TCP listener only on the loopback interface
    local -- pattern1='<Connector port="8009"'; pattern2='\/>';
    local -- replacement=''
    replacement+='<Connector port="8009"\n'
    replacement+='           URIEncoding="UTF-8"\n'
    replacement+='           enableLookups="false"\n'
    replacement+='           redirectPort="8443"\n'
    replacement+='           address="127.0.0.1"\n'
    replacement+='           protocol="AJP\/1.3"\/>'
    sed -i '/'"${pattern1}"'/{:a;N;/'"${pattern2}"'/!ba;N;s/.*\n/'"${replacement}"'\n/}' \
        "${EF_CONF_ROOT}/tomcat/conf/server.xml"

    # special configuration for newer version of openlava
    if [[ ${cfn_scheduler} == openlava ]]; then
        echo $'\nLSF_INTERACTIVE_USE_SHARED_FS="true"' \
            >> "${EF_CONF_ROOT}/plugins/lsf/ef.lsf.conf"
    fi

    # configure Apache HTTPD to publish EnginFrame
    cat > '/etc/httpd/conf.d/httpd-enginframe.conf' <<EOF
Header set X-UA-Compatible IE=edge
<Location /${EF_ROOT_CONTEXT}>
    ProxyPass        ajp://127.0.0.1:8009/${EF_ROOT_CONTEXT} flushpackets=on
    ProxyPassReverse ajp://127.0.0.1:8009/${EF_ROOT_CONTEXT}
</Location>
EOF

    # Apache directive ServerName should be equal to whatever is the CN of the certificate,
    # so let's use the the dns name associated with the public ip, if it exists, or the local hostname
    local -r publicHostname=$(curl -fsq 'http://169.254.169.254/latest/meta-data/public-hostname')
    local -r localHostname=$(curl -fsq 'http://169.254.169.254/latest/meta-data/local-hostname')
    local -r serverName="${publicHostname:-${localHostname}}"

    # create a self-signed certificate for Apache
    openssl req -x509 -new -nodes -newkey rsa:2048 -days 1024 \
        -keyout '/etc/httpd/conf.d/server.key' \
        -out '/etc/httpd/conf.d/server.crt' \
        -subj "/C=IT/ST=Piedmont/L=Asti/O=NICE/OU=ProServ/CN=${serverName}"

    # restrict access to the private key and the certificate
    chmod 400 '/etc/httpd/conf.d/server.key' \
              '/etc/httpd/conf.d/server.crt'

    # HTTP is disabled; use the proper server name
    sed -i \
        -e 's|Listen 80|#&|' \
        -e "s|#ServerName www.example.com:80|ServerName ${serverName}:80|" \
        '/etc/httpd/conf/httpd.conf'

    # configure apache to redirect to EnginFrame all requests that land on the top-level document root
    cat > '/var/www/html/index.html' <<EOF
<!DOCTYPE html>
<html>
  <head>
    <title>MyHPC</title>
    <meta http-equiv="refresh" content="0; URL=/${EF_ROOT_CONTEXT}/applications/applications.xml"/>
  </head>
  <body>
    <div style="text-align: center; font-family: sans-serif;">Page is loading, please wait...</div>
  </body>
</html>
EOF

    # change the index.html files of EnginFrame
    cp -f '/var/www/html/index.html' "${EF_CONF_ROOT}/tomcat/webapps/ROOT/index.html"
    cp -f '/var/www/html/index.html' "${EF_TOP}/${EF_VERSION}/enginframe/WEBAPP/index.html"

    # be sure both EnginFrame and Apache HTTPD start at boot time
    chkconfig enginframe on
    chkconfig httpd on

    # start both EnginFrame and Apache HTTPD on this master node
    service enginframe start
    service httpd restart

    # get the subnet of the second first zone
    local -r master_subnet_id_az0=$(getStackResource 'Subnet0')
    local -r az0=$(
        aws ec2 describe-subnets \
            --subnet-ids "${master_subnet_id_az0}" \
            --query 'Subnets[0].AvailabilityZone'
    )

    # get the subnet of the second availability zone
    local -r master_subnet_id_az1=$(getStackResource 'Subnet1')
    local -r az1=$(
        aws ec2 describe-subnets \
            --subnet-ids "${master_subnet_id_az1}" \
            --query 'Subnets[0].AvailabilityZone'
    )

    # get the primary security group
    local -r vpc_security_group_id=$(getStackResource 'MasterSecurityGroup')

    # get the instance profile to use with all instances
    # NOTE: even if this parameter name contains the word "role", it is actually an instance profile
    local -r ec2_iam_role=$(getStackResource 'RootInstanceProfile')

    # get the network address block that can access this environment
    local -r ssh_from=$(getStackParameter 'AccessFrom')

    # get the EC2 KeyPair name used in the main template
    local -r key_name=$(getStackParameter 'KeyName')

    # get the EC2 instance type of master nodes
    local -r master_instance_type=$(getStackParameter 'MasterInstanceType')

    # get the EC2 instance type of compute nodes
    local -r compute_instance_type=$(getStackParameter 'ComputeInstanceType')

    # get the initial number of EC2 instances to launch as compute nodes
    local -r initial_queue_size=$(getStackParameter 'MinSize')

    # get the maximum number of EC2 compute instances that can be launched in the cluster
    local -r max_queue_size=$(getStackParameter 'MaxSize')

    # get the flag to choose if maintain at least the number of compute instance equal to initial cluster size during autoscaling
    local -r maintain_initial_size=true

    # get the cluster scheduler
    local -r scheduler=$(getStackParameter 'Scheduler')

}

# this functions is executed on all cluster nodes and the master node;
# it installs some required packages and modifies the role policies
# to forbid further access to confidential information (aka passwords)
commonConfiguration() {

    echo '[info] commonConfiguration()'

    # install packages required by all node types
    apt-get install -y --disablerepo epel \
        xorg-x11-apps xorg-x11-utils \
        xorg-x11-fonts-75dpi xorg-x11-fonts-misc \
        ImageMagick tigervnc-server xterm

    # modify role policies
    aws iam put-role-policy \
        --role-name "${roleName}" \
        --policy-name "BlockInstance_${instanceId}" \
        --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "BlockCloudFormation",
      "Effect": "Deny",
      "Action": [
        "cloudformation:DescribeStacks",
        "cloudformation:DescribeStackResource",
        "cloudformation:DescribeStackResources"
      ],
      "Resource": "'"${InfrastructureStackId}"'",
      "Condition": {"StringLike": {"ec2:SourceInstanceARN": "*/'"${instanceId}"'"}}
    },
    { "Sid": "BlockIAM",
      "Effect": "Deny",
      "Action": "iam:PutRolePolicy",
      "Resource": "'"${roleArn}"'",
      "Condition": {"StringLike": {"ec2:SourceInstanceARN": "*/'"${instanceId}"'"}}
    }
  ]
}'
}

# query AWS to retrieve the id of a resource of the main CloudFormation stack
getStackResource() {
    local -r LogicalResourceId="$1"
    echo "${stackResources}" | jq -r \
        ".StackResources[] | select(.LogicalResourceId == \"${LogicalResourceId}\") | .PhysicalResourceId"
}

# query AWS to retrieve a parameter of the main CloudFormation stack
getStackParameter() {
    local -r parameterKey="$1"
    echo "${stackDescription}" | jq -r \
        ".Stacks[0].Parameters[] | select(.ParameterKey == \"${parameterKey}\") | .ParameterValue"
}


# the stdout and stderr of this script will go in this file:
# it's better we close it, so only root can access it
touch "/var/log/nice.postinstall.log"
chmod 400 "/var/log/nice.postinstall.log"

# here we invoke the main function
main "$@" 2>&1 | tee "/var/log/nice.postinstall.log"

# vim:syntax=sh
