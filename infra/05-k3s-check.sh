source ~/securebank-vpc.env
export AWS_DEFAULT_REGION=ap-southeast-2
MIP=$(aws ec2 describe-instances --instance-ids $K8SM --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
rm -f ~/k8skey ~/k8skey.pub; ssh-keygen -t ed25519 -N '' -f ~/k8skey -q
aws ec2-instance-connect send-ssh-public-key --instance-id $K8SM --instance-os-user ec2-user --ssh-public-key file://~/k8skey.pub >/dev/null
ssh -i ~/k8skey -o StrictHostKeyChecking=no -o ConnectTimeout=10 ec2-user@$MIP 'kubectl get nodes -o wide | cut -c1-90; echo; kubectl get deployment nginx-deployment; echo; kubectl get pods -o wide | cut -c1-100; echo; kubectl get svc nginx-service'
rm -f ~/k8skey ~/k8skey.pub
echo "--- NodePort 30080 from the internet ---"
for IP in $(aws ec2 describe-instances --instance-ids $K8SM $K8SW1 $K8SW2 --query 'Reservations[].Instances[].PublicIpAddress' --output text); do
  printf '%s -> ' $IP; curl -s -m 5 http://$IP:30080 | grep -o '<title>.*</title>' || echo 'no response'
done
echo "Open in browser: http://$MIP:30080"
echo K8S_CHECK_DONE
