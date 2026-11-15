set -e
export AWS_DEFAULT_REGION=ap-southeast-2
tag(){ aws ec2 create-tags --resources "$1" --tags Key=Name,Value="$2" Key=Project,Value=SecureBank; }
VPC=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query Vpc.VpcId --output text); tag $VPC securebank-vpc
aws ec2 modify-vpc-attribute --vpc-id $VPC --enable-dns-hostnames
IGW=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text); tag $IGW securebank-igw
aws ec2 attach-internet-gateway --vpc-id $VPC --internet-gateway-id $IGW
mk(){ S=$(aws ec2 create-subnet --vpc-id $VPC --cidr-block $1 --availability-zone $2 --query Subnet.SubnetId --output text); tag $S $3; echo $S; }
PUBA=$(mk 10.0.1.0/24 ap-southeast-2a securebank-public-a)
PUBB=$(mk 10.0.2.0/24 ap-southeast-2b securebank-public-b)
PRIA=$(mk 10.0.11.0/24 ap-southeast-2a securebank-private-a)
PRIB=$(mk 10.0.12.0/24 ap-southeast-2b securebank-private-b)
for S in $PUBA $PUBB; do aws ec2 modify-subnet-attribute --subnet-id $S --map-public-ip-on-launch; done
PUBRT=$(aws ec2 create-route-table --vpc-id $VPC --query RouteTable.RouteTableId --output text); tag $PUBRT securebank-public-rt
aws ec2 create-route --route-table-id $PUBRT --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW >/dev/null
PRIRT=$(aws ec2 create-route-table --vpc-id $VPC --query RouteTable.RouteTableId --output text); tag $PRIRT securebank-private-rt
for S in $PUBA $PUBB; do aws ec2 associate-route-table --route-table-id $PUBRT --subnet-id $S >/dev/null; done
for S in $PRIA $PRIB; do aws ec2 associate-route-table --route-table-id $PRIRT --subnet-id $S >/dev/null; done
# Security groups: ALB (80 from internet) -> web (80 from ALB, 22 from anywhere for demo)
ALBSG=$(aws ec2 create-security-group --group-name securebank-alb-sg --description "SecureBank ALB - HTTP from internet" --vpc-id $VPC --query GroupId --output text); tag $ALBSG securebank-alb-sg
aws ec2 authorize-security-group-ingress --group-id $ALBSG --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
WEBSG=$(aws ec2 create-security-group --group-name securebank-vpc-web-sg --description "SecureBank web tier - HTTP from ALB only" --vpc-id $VPC --query GroupId --output text); tag $WEBSG securebank-vpc-web-sg
aws ec2 authorize-security-group-ingress --group-id $WEBSG --protocol tcp --port 80 --source-group $ALBSG >/dev/null
aws ec2 authorize-security-group-ingress --group-id $WEBSG --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null
cat > ~/securebank-vpc.env <<EOF
VPC=$VPC
IGW=$IGW
PUBA=$PUBA
PUBB=$PUBB
PRIA=$PRIA
PRIB=$PRIB
PUBRT=$PUBRT
PRIRT=$PRIRT
ALBSG=$ALBSG
WEBSG=$WEBSG
EOF
cat ~/securebank-vpc.env
echo VPC_OK
