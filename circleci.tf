# Configure the AWS Provider

# AWS Specific configuration
variable "aws_access_key" {
    description = "Access key used to create instances"
}

variable "aws_secret_key" {
    description = "Secret key used to create instances"
}

variable "aws_region" {
    description = "Region where instances get created"
}

variable "aws_vpc_id" {
    description = "The VPC ID where the instances should reside"
}

variable "aws_subnet_id" {
    description = "The subnet-id to be used for the instance"
}

variable "aws_ssh_key_name" {
    description = "The SSH key to be used for the instances"
}

variable "circle_secret_passphrase" {
    description = "Decryption key for secrets used by CircleCI machines"
}

variable "services_instance_type" {
    description = "instance type for the centralized services box.  We recommend a c4 instance"
    default = "c4.2xlarge"
}

variable "builder_instance_type" {
    description = "instance type for the builder machines.  We recommend a r3 instance"
    default = "r3.2xlarge"
}

variable "max_builders_count" {
    description = "max number of builders"
    default = "2"
}

variable "prefix" {
    description = "prefix for resource names"
    default = "circleci"
}

data "aws_subnet" "subnet" {
  id = "${var.aws_subnet_id}"
}

provider "aws" {
    access_key = "${var.aws_access_key}"
    secret_key = "${var.aws_secret_key}"
    region = "${var.aws_region}"
}

# SQS queue for hook

resource "aws_sqs_queue" "shutdown_queue" {
    name = "${var.prefix}_queue"
}


# IAM for shutdown queue

resource "aws_iam_role" "shutdown_queue_role" {
    name = "${var.prefix}_shutdown_queue_role"
    assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "autoscaling.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "shutdown_queue_role_policy" {
    name = "${var.prefix}_shutdown_queue_role"
    role = "${aws_iam_role.shutdown_queue_role.id}"
    policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "sqs:GetQueueUrl",
        "sqs:SendMessage"
      ],
      "Effect": "Allow",
      "Resource": [ "${aws_sqs_queue.shutdown_queue.arn}" ]
    }
  ]
}
EOF
}

# Single general-purpose bucket

resource "aws_s3_bucket" "circleci_bucket" {
    # VPC ID is used here to make bucket name globally unique(ish) while
    # uuid/ignore_changes have some lingering issues
    bucket = "${replace(var.prefix, "_", "-")}-bucket-${replace(var.aws_vpc_id, "vpc-", "")}"
    cors_rule {
        allowed_methods = ["GET"]
        allowed_origins = ["*"]
        max_age_seconds = 3600
    }
}

## IAM for instances

resource "aws_iam_role" "circleci_role" {
    name = "${var.prefix}_role"
    path = "/"
    assume_role_policy = <<EOF
{
   "Version": "2012-10-17",
    "Statement" : [
       {
          "Action" : ["sts:AssumeRole"],
          "Effect" : "Allow",
          "Principal" : {
            "Service": ["ec2.amazonaws.com"]
          }
       }
    ]
}
EOF
}

resource "aws_iam_role_policy" "circleci_policy" {
  name = "${var.prefix}_policy"
  role = "${aws_iam_role.circleci_role.id}"
  policy = <<EOF
{
   "Version": "2012-10-17",
   "Statement" : [
      {
         "Action" : ["s3:*"],
         "Effect" : "Allow",
         "Resource" : [
            "${aws_s3_bucket.circleci_bucket.arn}",
            "${aws_s3_bucket.circleci_bucket.arn}/*"
         ]
      },
      {
          "Action" : [
              "sqs:*"
          ],
          "Effect" : "Allow",
          "Resource" : ["${aws_sqs_queue.shutdown_queue.arn}"]
      },
      {
          "Action": [
              "ec2:Describe*",
              "ec2:CreateTags",
	      "cloudwatch:*",
              "iam:GetUser",
              "autoscaling:CompleteLifecycleAction"
          ],
          "Resource": ["*"],
          "Effect": "Allow"
      }
   ]
}
EOF
}

resource "aws_iam_instance_profile" "circleci_profile" {
  name = "${var.prefix}_profile"
  roles = ["${aws_iam_role.circleci_role.name}"]
}


## Configure the services machine

resource "aws_security_group" "circleci_builders_sg" {
    name = "${var.prefix}_builders_sg"
    description = "SG for CircleCI Builder instances"

    vpc_id = "${var.aws_vpc_id}"
    ingress {
        self = true
        from_port = 0
        to_port = 0
        protocol = "-1"
    }
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

resource "aws_security_group" "circleci_services_sg" {
    name = "${var.prefix}_services_sg"
    description = "SG for CircleCI services/database instances"

    vpc_id = "${var.aws_vpc_id}"
    ingress {
        security_groups = ["${aws_security_group.circleci_builders_sg.id}"]
        protocol = "-1"
        from_port = 0
        to_port = 0
    }
    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }

    # If using github.com (not GitHub Enterprise) whitelist GitHub cidr block
    # https://help.github.com/articles/what-ip-addresses-does-github-use-that-i-should-whitelist/
    #
    #ingress {
    #    security_groups = ["192.30.252.0/22"]
    #    protocol = "tcp"
    #    from_protocol = 443
    #    to_protocol = 443
    #}
    #ingress {
    #    security_groups = ["192.30.252.0/22"]
    #    protocol = "tcp"
    #    from_protocol = 80
    #    to_protocol = 80
    #}
}

resource "aws_security_group" "circleci_builders_admin_sg" {
    name = "${var.prefix}_builders_admin_sg"
    description = "SG for services to masters communication - avoids circular dependency"

    vpc_id = "${var.aws_vpc_id}"
    ingress {
        security_groups = ["${aws_security_group.circleci_services_sg.id}"]
        protocol = "tcp"
        from_port = 443
        to_port = 443
    }
}

#
# This should be configured by admins to restrict access to machines
# TODO: Make this more extensible
#
resource "aws_security_group" "circleci_users_sg" {
    name = "${var.prefix}_users_sg"
    description = "SG representing users of CircleCI Enterprise"

    vpc_id = "${var.aws_vpc_id}"
    ingress {
        cidr_blocks = ["0.0.0.0/0"]
        protocol = "tcp"
        from_port = 22
        to_port = 22
    }
    # For Web traffic to services
    ingress {
        cidr_blocks = ["0.0.0.0/0"]
        protocol = "tcp"
        from_port = 80
        to_port = 80
    }
    ingress {
        cidr_blocks = ["0.0.0.0/0"]
        protocol = "tcp"
        from_port = 443
        to_port = 443
    }
    # TODO: Maybe don't expose this
    ingress {
        cidr_blocks = ["0.0.0.0/0"]
        protocol = "tcp"
        from_port = 4434
        to_port = 4434
    }
    ingress {
        cidr_blocks = ["0.0.0.0/0"]
        protocol = "tcp"
        from_port = 8800
        to_port = 8800
    }

    # For Nomad server in 2.0 clustered installation
    ingress {
        cidr_blocks = ["${data.aws_subnet.subnet.cidr_block}"]
        protocol = "tcp"
        from_port = 4647
        to_port = 4647
    }

    # For output-processor in 2.0 clustered installation
    ingress {
        cidr_blocks = ["${data.aws_subnet.subnet.cidr_block}"]
        protocol = "tcp"
        from_port = 8585
        to_port = 8585
    }

    # For SSH traffic to builder boxes
    # TODO: Update once services box has ngrok
    ingress {
        cidr_blocks = ["0.0.0.0/0"]
        protocol = "tcp"
        from_port = 64535
        to_port = 65535
    }
}

variable "base_services_image" {
    default = {
      # This can just be the Canonical Trusty image for your region
      us-east-1 = "ami-772aa961"
    }
}

variable "builder_image" {
    default = {
      ap-northeast-1 = "ami-38d8fa5f"
      ap-northeast-2 = "ami-5ff22031"
      ap-southeast-1 = "ami-381aa45b"
      ap-southeast-2 = "ami-76bab415"
      eu-central-1 = "ami-46d50729"
      eu-west-1 = "ami-c8b288ae"
      sa-east-1 = "ami-af5c3ec3"
      us-east-1 = "ami-4d75f85b"
      us-east-2 = "ami-b78ca8d2"
      us-west-1 = "ami-8d0124ed"
      us-west-2 = "ami-feef7c9e"
    }
}

## Services ASG
resource "aws_elb" "services_elb" {
    name = "${replace(var.prefix, "_", "-")}-elb"

    subnets = ["${var.aws_subnet_id}"]
    security_groups = ["${aws_security_group.circleci_users_sg.id}",
                       "${aws_security_group.circleci_services_sg.id}"]

  listener {
    instance_port     = 80
    instance_protocol = "tcp"
    lb_port           = 80
    lb_protocol       = "tcp"
  }

  listener {
    instance_port     = 443
    instance_protocol = "tcp"
    lb_port           = 443
    lb_protocol       = "tcp"
  }

  listener {
    instance_port     = 8800
    instance_protocol = "tcp"
    lb_port           = 8800
    lb_protocol       = "tcp"
  }

  # TODO: Maybe don't expose this
  listener {
    instance_port     = 4434
    instance_protocol = "tcp"
    lb_port           = 4434
    lb_protocol       = "tcp"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "TCP:80"
    interval            = 30
  }
}

resource "aws_launch_configuration" "services_lc" {
    instance_type = "${var.services_instance_type}"


    image_id = "${lookup(var.base_services_image, var.aws_region)}"
    key_name = "${var.aws_ssh_key_name}"

    security_groups = ["${aws_security_group.circleci_services_sg.id}",
                       "${aws_security_group.circleci_users_sg.id}"]

    iam_instance_profile = "${aws_iam_instance_profile.circleci_profile.name}"

    # TODO: Make mongo startup conditional so this device doesn't always need to be big
    root_block_device {
        volume_type = "gp2"
	volume_size = "50"
	delete_on_termination = true
    }

    user_data = <<EOF
#!/bin/bash

set -ex

startup() {
  apt-get update; apt-get install -y python-pip
  pip install awscli
  aws s3 cp s3://ha-test-bucket-3f5b105a/settings.conf /etc/settings.conf
  aws s3 cp s3://ha-test-bucket-3f5b105a/replicated.conf /etc/replicated.conf
  aws s3 cp s3://ha-test-bucket-3f5b105a/license.rli /etc/license.rli
  aws s3 cp s3://ha-test-bucket-3f5b105a/circle-installation-customizations /etc/circle-installation-customizations
  curl https://get.replicated.com/docker | bash -s local_address=$(curl http://169.254.169.254/latest/meta-data/local-ipv4) no_proxy=1
}

time startup

EOF

    # Can't delete an LC until the replacement is applied
    lifecycle {
      create_before_destroy = true
    }
}

resource "aws_autoscaling_group" "services_asg" {
    name = "${var.prefix}_services_asg"

    vpc_zone_identifier = ["${var.aws_subnet_id}"]
    launch_configuration = "${aws_launch_configuration.services_lc.name}"
    load_balancers = ["${aws_elb.services_elb.name}"]
    max_size = 1
    min_size = 1
    desired_capacity = 1
    force_delete = true
    tag {
      key = "Name"
      value = "${var.prefix}_services"
      propagate_at_launch = "true"
    }
}

## Builders ASG
resource "aws_launch_configuration" "builder_lc" {
    # 4x or 8x are best
    instance_type = "${var.builder_instance_type}"


    image_id = "${lookup(var.builder_image, var.aws_region)}"
    key_name = "${var.aws_ssh_key_name}"

    security_groups = ["${aws_security_group.circleci_builders_sg.id}",
                       "${aws_security_group.circleci_builders_admin_sg.id}",
                       "${aws_security_group.circleci_users_sg.id}"]

    iam_instance_profile = "${aws_iam_instance_profile.circleci_profile.name}"

    user_data = <<EOF
#!/bin/bash

apt-cache policy | grep circle || curl https://s3.amazonaws.com/circleci-enterprise/provision-builder.sh | bash
curl https://s3.amazonaws.com/circleci-enterprise/init-builder-0.2.sh | \
    SERVICES_PRIVATE_IP='${aws_elb.services_elb.dns_name}' \
    CIRCLE_SECRET_PASSPHRASE='${var.circle_secret_passphrase}' \
    bash

EOF

    # To enable using spots
    # spot_price = "1.00"

    # Can't delete an LC until the replacement is applied
    lifecycle {
      create_before_destroy = true
    }
}

resource "aws_autoscaling_group" "builder_asg" {
    name = "${var.prefix}_builders_asg"

    vpc_zone_identifier = ["${var.aws_subnet_id}"]
    launch_configuration = "${aws_launch_configuration.builder_lc.name}"
    max_size = "${var.max_builders_count}"
    min_size = 0
    desired_capacity = 1
    force_delete = true
    tag {
      key = "Name"
      value = "${var.prefix}_builder"
      propagate_at_launch = "true"
    }
}

# Shutdown hooks

resource "aws_autoscaling_lifecycle_hook" "builder_shutdown_hook" {
    name = "builder_shutdown_hook"
    autoscaling_group_name = "${aws_autoscaling_group.builder_asg.name}"
    heartbeat_timeout = 3600
    lifecycle_transition = "autoscaling:EC2_INSTANCE_TERMINATING"
    notification_target_arn = "${aws_sqs_queue.shutdown_queue.arn}"
    role_arn = "${aws_iam_role.shutdown_queue_role.arn}"
}
