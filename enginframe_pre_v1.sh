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
# before everything else, in particular before Chef configures the scheduler

# do not remember history
set +o history

# this temporary directory will be removed by the following trap even in case of error
declare -r tmpDir=$(mktemp --directory)
trap 'rm -rf "${tmpDir}"' EXIT

# this file is created by CfnCluster
source '/etc/parallelcluster/cfnconfig'

# the variable cfn_region is defined inside /etc/cfncluster/cfnconfig
declare -x AWS_DEFAULT_REGION="${cfn_region}"
# special AWS variable that simplifies the parsing of AWS CLI output
declare -x AWS_DEFAULT_OUTPUT='text'

# stdout and stderr of the main function are redirected to /var/log/nice.preinstall.log
main() {

    echo '[info] enginframe.pre.sh'

    # best practice: never upgrade the kernel
    #sed -i 's/\[main\]/&\nexclude=kernel*/' '/etc/yum.conf'

    # update rpm packages, without checking epel repository
    # because sometime it is not accessible by the instances
    apt-get update -y --disablerepo epel

    # install some packages that will be useful later on with EFS and SimpleDirectory
    apt-get install -y --disablerepo epel \
        jq sssd sssd-tools samba-common-tools samba-libs realmd krb5-workstation adcli openldap-clients nfs-utils

    # these meta-data are always available within an instance, no role/policy required
    local -r macAddress=$(curl -fsq 'http://169.254.169.254/latest/meta-data/mac')
    local -r vpcId=$(curl -fsq "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${macAddress}/vpc-id")

    # this is the stack id of the main cloudformation stack, the one that was at the beginning;
    # keep in mind that script might be executed by an instance launched by hand with cfncluster/cfnconfig
    # so we cannot use the stackId of the "current" cloudformation stack, because it is a different id
    local -r stackId=$(
        aws ec2 describe-vpcs \
            --vpc-ids "${vpcId}" \
            --query 'Vpcs[0].Tags[?Key==`aws:cloudformation:stack-id`].Value'
    )

    # now we can use the stack Id of the main stack to retrieve its resources
    local -r efsId=$(
        aws cloudformation describe-stack-resource \
            --stack-name "${stackId}" \
            --logical-resource-id 'FileSystem' \
            --query 'StackResourceDetail.PhysicalResourceId'
    )
    local -r metadata=$(
        aws cloudformation describe-stack-resource \
            --stack-name "${stackId}" \
            --logical-resource-id 'DirectoryService' \
            --query 'StackResourceDetail.Metadata'
    )

    # this is possible only if this script is used with a vpc
    # that was not created by the standard cloudformation template
    # or if this script is executed a second time,
    # after the policy changes done by the post-install script
    if [[ -z ${metadata} ]]; then
        echo "[ERROR] unable to retrieve stack metadata" >&2
        return 1
    fi

    # the password are encrypted using AWS KMS (see the function decrypt() below)
    local -- efadminPassword=${EnginFrameAdminPassword}

    # do not check the ssh host key, useful for mpi jobs
    local -r ssh_config='/etc/ssh/ssh_config'
    sed -i '/StrictHostKeyChecking/d' "${ssh_config}"
    echo 'StrictHostKeyChecking no' >> "${ssh_config}"

    # this profile script creates a key pair for passwordless ssh, useful for mpi jobs;
    # note that it explicitly does not work for root and whoever is $cfn_cluster_user
    # as defined inside /etc/cfncluster/cfnconfig (ec2-user for alinux, centos for centos, ...)
    local -r profile='/etc/profile.d/myhpc.sh'
    cat > "${profile}" <<'EOF'
#!/bin/bash
source '/etc/parallelcluster/cfnconfig'
[[ $(id --user --name) =~ ^(root|${cfn_cluster_user})$ ]] && return 0
if [[ ! -d ${HOME}/.ssh ]] \
|| [[ ! -f ${HOME}/.ssh/id_rsa ]] \
|| [[ ! -f ${HOME}/.ssh/id_rsa.pub ]]; then
    ssh-keygen -t rsa -N '' -f "${HOME}/.ssh/id_rsa" <<< $'y'
fi
cat "${HOME}/.ssh/id_rsa.pub" >> "${HOME}/.ssh/authorized_keys"
sort "${HOME}/.ssh/authorized_keys" | uniq > "${HOME}/.ssh/authorized_keys.new"
mv -f "${HOME}/.ssh/authorized_keys.new" "${HOME}/.ssh/authorized_keys"
chmod 640 "${HOME}/.ssh/authorized_keys"
EOF
    chown root:root "${profile}"; chmod 755 "${profile}"

    if [[ -n ${efadminPassword} ]]; then

            # restart sssd service, so the changes are applied
            service sssd restart

        # if there is no domain password, then probably AWS DS is not available in the current region: use local accounts instead
        else
            # this is the standard linux command
            useradd --uid=1999 'efadmin'
            useradd --uid=1998 'efnobody'

            # the password is passed to the stdin of command "passwd" twice
            passwd 'efadmin' <<< "${efadminPassword}"$'\n'"${efadminPassword}"$'\n'
            # let's create some common user accounts
            local -i uid; for uid in {1..10}; do
                useradd --uid="$((2000 + uid))" "user$(printf '%03d' "${uid}")"
            done
        fi
    fi

    # wait until efadmin is active until timeout
    local -i counter=24
    while ((counter--)) && ! id 'efadmin'; do sleep 5; done

    # give ownership of the shared folder to efadmin and its primary group
    local efadminGroup=$(id --group --name efadmin)

    # if you want efadmin to be sudoer, uncomment the following line
    # makeSudoer 'efadmin'

    # this message will be the last line of the stdout of this script,
    # so it can be easily found in the log of cloudformation (/var/log/cloud* and /var/log/cfn*)
    echo '[info] preinstall completed'
}


# this function creates a file under /etc/sudoers.d/ to promote a user to sudoer
makeSudoer() {
    local -- user="$1"
    local -- file="/etc/sudoers.d/99-${user}"
    printf 'Defaults:%s !requiretty\n%s ALL=(ALL:ALL) ALL\n' "${user}" "${user}" > "${file}"
    chmod 400 "${file}"
}

# the stdout and stderr of this script will go in this file:
# it's better we close it, so only root can access it
touch "/var/log/nice.preinstall.log"
chmod 400 "/var/log/nice.preinstall.log"

# here we invoke the main function
main "$@" 2>&1 | tee "/var/log/nice.preinstall.log"

# vim:syntax=sh
