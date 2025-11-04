# AWS IAM Policy for MLflow S3 Access

This document describes the IAM permissions required for MLflow to access your S3 bucket for artifact storage.

## Minimum Required IAM Policy

Create an IAM policy with the following permissions and attach it to the IAM user whose credentials you'll use:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::YOUR-BUCKET-NAME",
        "arn:aws:s3:::YOUR-BUCKET-NAME/*"
      ]
    }
  ]
}
```

## Creating IAM User and Policy

### Step 1: Create IAM User

```
aws iam create-user --user-name mlflow-s3-user
```

### Step 2: Create IAM Policy

Save the policy JSON to a file (e.g., `mlflow-s3-policy.json`) and create the policy:

```
aws iam create-policy \
  --policy-name MLflowS3Access \
  --policy-document file://mlflow-s3-policy.json
```

### Step 3: Attach Policy to User

```
aws iam attach-user-policy \
  --user-name mlflow-s3-user \
  --policy-arn arn:aws:iam::YOUR-ACCOUNT-ID:policy/MLflowS3Access
```

### Step 4: Create Access Keys

```
aws iam create-access-key --user-name mlflow-s3-user
```

This will output the `AccessKeyId` and `SecretAccessKey` that you'll use in the `01-namespace.yaml` secret.

### Testing from MLflow Pod

You can exec into the MLflow pod to test S3 access:

```
oc exec -it deployment/mlflow-server -n mlflow -- bash

# Inside the pod
python3 << EOF
import boto3
s3 = boto3.client('s3')
print(s3.list_objects_v2(Bucket='YOUR-BUCKET-NAME'))
EOF
```
