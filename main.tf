provider "aws" {
    region = "ap-south-1"  
}


resource "aws_security_group" "securitygroup" {
    name = "securitygroup"
    description = "security group for module"

    ingress = {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
  
}
