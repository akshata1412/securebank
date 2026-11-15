set -e
export AWS_DEFAULT_REGION=ap-southeast-2
source ~/securebank-vpc.env
K8SG=$(aws ec2 create-security-group --group-name securebank-k8s-sg --description "SecureBank k3s cluster" --vpc-id $VPC --query GroupId --output text)
aws ec2 create-tags --resources $K8SG --tags Key=Name,Value=securebank-k8s-sg Key=Project,Value=SecureBank
aws ec2 authorize-security-group-ingress --group-id $K8SG --ip-permissions \
 "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$K8SG,Description=node-to-node}]" \
 "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=0.0.0.0/0,Description=ssh}]" \
 "IpProtocol=tcp,FromPort=30080,ToPort=30080,IpRanges=[{CidrIp=0.0.0.0/0,Description=nginx NodePort}]" >/dev/null
TOKEN=$(openssl rand -hex 24)
AMI=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
cat > ~/k3s-server.sh <<EOF
#!/bin/bash
fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
curl -sfL https://get.k3s.io | K3S_TOKEN=$TOKEN INSTALL_K3S_EXEC="server --node-name master --write-kubeconfig-mode 644 --disable traefik" sh -
cat > /root/nginx.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
  labels: {app: nginx}
spec:
  replicas: 3
  selector:
    matchLabels: {app: nginx}
  template:
    metadata:
      labels: {app: nginx}
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  type: NodePort
  selector: {app: nginx}
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
YAML
cp /root/nginx.yaml /home/ec2-user/nginx.yaml
for i in \$(seq 1 60); do [ "\$(/usr/local/bin/kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready')" -ge 3 ] && break; sleep 10; done
/usr/local/bin/kubectl apply -f /root/nginx.yaml
EOF
run(){ aws ec2 run-instances --image-id $AMI --instance-type t3.micro --subnet-id $1 --security-group-ids $K8SG --key-name securebank-key --user-data file://$2 --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$3},{Key=Project,Value=SecureBank}]" --query 'Instances[0].[InstanceId,PrivateIpAddress]' --output text; }
read M MIP < <(run $PUBA ~/k3s-server.sh securebank-k8s-master)
cat > ~/k3s-agent.sh <<EOF
#!/bin/bash
fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
until curl -sk https://$MIP:6443 >/dev/null; do sleep 10; done
curl -sfL https://get.k3s.io | K3S_URL=https://$MIP:6443 K3S_TOKEN=$TOKEN INSTALL_K3S_EXEC="agent --node-name \$(hostname -s | sed 's/^/worker-/')" sh -
EOF
read W1 W1IP < <(run $PUBA ~/k3s-agent.sh securebank-k8s-worker-1)
read W2 W2IP < <(run $PUBB ~/k3s-agent.sh securebank-k8s-worker-2)
printf 'K8SG=%s\nK8SM=%s\nK8SW1=%s\nK8SW2=%s\n' $K8SG $M $W1 $W2 >> ~/securebank-vpc.env
aws ec2 wait instance-running --instance-ids $M $W1 $W2
aws ec2 describe-instances --instance-ids $M $W1 $W2 --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,PrivateIpAddress,PublicIpAddress]' --output table
echo K8S_LAUNCHED
