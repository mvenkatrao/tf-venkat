provider "aws" {
    region = "ap-south-1"  
}

resource "aws_instance" "UbuntuInstance" {
    count           = 2
    ami             = "ami-0a14f53a6fe4dfcd1"
    instance_type   = "t2.micro"
    security_groups = ["default"]
    key_name = "venkat"
    
    tags = {
        Name = "Terraform-Instance"
    }
  
}
