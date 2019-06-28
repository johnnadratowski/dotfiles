function swap_access_keys () {
	local backupAwsKey=$(mktemp)
	echo "Making backup of Aws Credentials"
	cp -f ~/.aws/credentials $backupAwsKey
	echo "Made backup of aws keys: $backupAwsKey"
	local oldAccessKey
	oldAccessKey=$(cat ~/.aws/credentials | grep aws_access_key_id | cut -d' ' -f3) || { echo "failed"; return }
	echo "Old Access Key: $oldAccessKey"
	local filename="$(mktemp)"
	echo "Getting new Access Key. Temp New Cred File: $filename"
	aws iam create-access-key > $filename || { echo "failed"; return }
	echo "New Creds:$(cat $filename)"
	local accessKeyID
	accessKeyID=$(cat $filename | jq -r .AccessKey.AccessKeyId) || { echo "failed"; return }
	echo "New Access Key ID: $accessKeyID"
	local accessKeySecret
	accessKeySecret=$(cat $filename | jq -r .AccessKey.SecretAccessKey) || { echo "failed"; return }
	echo "New Access Key Secret: $accessKeySecret"
	local tmpCreds=$(mktemp)
	echo "Replacing credentials file. Old file:\n\n$(cat ~/.aws/credentials)"
	sed "s/^aws_access_key_id = .*$/aws_access_key_id = $accessKeyID/" ~/.aws/credentials > $tmpCreds || { echo "failed"; return }
	mv -f $tmpCreds ~/.aws/credentials || { echo "failed"; return }
	sed "s|^aws_secret_access_key = .*$|aws_secret_access_key = $accessKeySecret|g" ~/.aws/credentials > $tmpCreds || { echo "failed"; return }
	mv -f $tmpCreds ~/.aws/credentials || { echo "failed"; return }
	echo "New credentials file:\n\n$(cat ~/.aws/credentials)"
	echo "Checking credentials worked"
	if ! aws sts get-caller-identity; then
		echo "Credentials check failed"
	else
		echo "Credential check succeeded"
	fi

	echo "Deleting old access key"
	aws iam delete-access-key --access-key-id $oldAccessKey || { echo "failed"; return }
}
