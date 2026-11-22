# shellcheck shell=bash
# AWS provider — phase 2 (not implemented yet).
#
# Planned shape: EC2 GPU instance (g6/g6e/p5) from a Deep Learning AMI, running the same
# container image (image/) with user-data `docker run --gpus all -p 8080:8080 -e ...`.
# Name tag = instance name (carries the expiry), terminate on down/reap.
# Implement the functions below following providers/README.md; nothing else needs to change.

_aws_todo() { die "the AWS provider is not implemented yet (phase 2). Use provider=runpod."; }

provider_validate()  { _aws_todo; }
provider_list()      { _aws_todo; }
provider_create()    { _aws_todo; }
provider_url()       { _aws_todo; }
provider_status()    { _aws_todo; }
provider_terminate() { _aws_todo; }
