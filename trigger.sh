#!/bin/bash
# script to launch trigger and nodered command
# rev 2.0 - 09.03.21 Francesco
DEBUG=1

nodered_deploy() {

 DATA="/data"
 TEMP="/ieam/data"

 DEPLOY_ID=""
 DEPLOY_USERNAME=""

 if [[ $DEBUG == 1 ]]; then echo "DEBUG: Check $TEMP/deploy.json"; fi
 eval $(jq -r 'to_entries[] | .key + "=\"" + .value + "\""' "$TEMP/deploy.json")

 if [[ $BUILD_MODE == 'true' ]]; then

  if [[ $DEBUG == 1 ]]; then echo "DEBUG: Set Build Mode"; fi
  BUILD_MODE=1
  
  DEPLOY_TARGET_LINK=$DEPLOY_TARGET_LINK
  DEPLOY_TARGET_PORT=$DEPLOY_TARGET_PORT
  
  fi

 if [[ $DEPLOY_PRESERVELOCAL == 'true' ]]; then

  if [[ $DEBUG == 1 ]]; then echo "DEBUG: Preserve local found"; fi
  return -1
  fi

 if [ ! -z $DEPLOY_ID ]; then
  
  if [[ $DEBUG == 1 ]]; then echo "DEBUG: OK proceed deploy_id=$DEPLOY_ID [$DEPLOY_OWNER] - $DEPLOY_DESCRIPTION"; fi
  ACCESS_TOKEN=""

  if [ ! -z $DEPLOY_USERNAME ]; then

   if [[ $DEBUG == 1 ]]; then echo "DEBUG: use username/password"; fi
   HTTP_CODE=$(curl -sSLw "%{http_code}" -o auth.token http://localhost:1880/auth/token --data "client_id=node-red-admin&grant_type=password&scope=*&username=${DEPLOY_USERNAME}&password=${DEPLOY_PASSWORD}")

   if [[ "$HTTP_CODE" != '200' ]]; then

    if [[ $DEBUG == 1 ]]; then echo "DEBUG: fail AUTH-TOKEN"; fi
    return -3
    fi

   if [[ "$HTTP_CODE" == '200' ]]; then

    if [[ $DEBUG == 1 ]]; then echo "DEBUG: ok AUTH-TOKEN"; fi
    ACCESS_TOKEN=$(jq -r .access_token auth.token)

   fi
  fi

  if [ ! -e ${TEMP}/flows_cred.json ]; then 
  
	if [[ $DEBUG == 1 ]]; then echo "DEBUG: Create default credentials"; fi
	echo "{}" > ${TEMP}/flows_cred.json
	fi
	
  if [ ! -e ${TEMP}/flows.json ]; then 
	
	if [[ $DEBUG == 1 ]]; then echo "DEBUG: Create default flows"; fi
	echo "[]" > ${TEMP}/flows.json
	fi

  cat <<-EOF > target.json
{
"flows": $(cat $TEMP/flows.json),
"credentials": $(cat $TEMP/flows_cred.json)
}
EOF

  if [ -z $ACCESS_TOKEN ]; then

   if [[ $DEBUG == 1 ]]; then echo "DEBUG: deploy without ACCESS_TOKEN"; fi
   HTTP_CODE=$(curl -sSLw "%{http_code}" -o deploy.rc -X POST http://localhost:1880/flows  -H "Content-Type: application/json" -H "Node-RED-API-Version: v2" --data "@target.json")

  else

   if [[ $DEBUG == 1 ]]; then echo "DEBUG: deploy with ACCESS_TOKEN"; fi
   HTTP_CODE=$(curl -sSLw "%{http_code}" -o deploy.rc -X POST http://localhost:1880/flows  -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json" -H "Node-RED-API-Version: v2" --data "@target.json")
   fi

  if [[ $DEBUG == 1 ]]; then echo "DEBUG: RC $HTTP_CODE"; fi
  if [[ "$HTTP_CODE" == '200' ]]; then

   return 0

  fi

  return -2
 fi

 return 99
 }

#GOTO rooot
cd /ieam

# Build Mode
BUILD_MODE=0
DEPLOY_TARGET_PORT=80
DEPLOY_TARGET_LINK="abc"
DEPLOY_ID="---"
DEPLOY_TYPE="---"

# The type and name of the MMS file we are using
OBJECT_ID="$HZN_DEVICE_ID.nodered-v2-deployment"
OBJECT_TYPE="deploy.tar"
OBJECT_RECEIVED=0

# ${HZN_ESS_AUTH} is mounted to this container by the Horizon agent and is a json file with the credentials for authenticating to ESS.
# ESS (Edge Sync Service) is a proxy to MMS that runs in the Horizon agent.
USER=$(cat ${HZN_ESS_AUTH} | jq -r ".id")
PW=$(cat ${HZN_ESS_AUTH} | jq -r ".token")

# Some curl parameters for using the ESS REST API
AUTH="-u ${USER}:${PW}"
# ${HZN_ESS_CERT} is mounted to this container by the Horizon agent and the cert clients use to verify the identity of ESS.
CERT="--cacert ${HZN_ESS_CERT}"
SOCKET="--unix-socket ${HZN_ESS_API_ADDRESS}"
BASEURL="https://localhost/api/v1/objects"

DATA="/data"
TEMP="/ieam/data"

if [[ $DEBUG == 1 ]]; then echo "DEBUG: pkill previous node-red";fi
pkill node-red
sleep 2
		
		
if [[ $DEBUG == 1 ]]; then echo "DEBUG: CLEAN ${TEMP}"; fi
if [ -e ${TEMP} ]; then rm -R ${TEMP}; fi
mkdir ${TEMP}

if [[ $DEBUG == 1 ]]; then echo "DEBUG: DEPLOY DEFAULT CONFIG"; fi
tar -xvf $OBJECT_TYPE -C $TEMP
if [ -e ${TEMP}/settings.js ]; then 
	
	if [[ $DEBUG == 1 ]]; then echo "DEBUG: COPY settings.js to $DATA"; fi
	cp "${TEMP}/settings.js" "$DATA/"
	fi

su - node-red -c "node-red --userDir /data flows.json" &

sleep 10

#deploy initial
if [[ $DEBUG == 1 ]]; then echo "DEBUG: Initial deployment" ; fi
nodered_deploy

# Save original config file that came from the docker image so we can revert back to it if the MMS file is deleted
cp $OBJECT_TYPE ${OBJECT_TYPE}.base

# BUILD MODE VAR
### Set initial time of file
LTIME1=`stat -c %Z $DATA/flows.json`
LTIME2=`stat -c %Z $DATA/flows_cred.json`

if [ ! -e ${DATA}/flows.json ]; then LTIME1="0"; fi
if [ ! -e ${DATA}/flows_cred.json ]; then LTIME2="0"; fi

# Repeatedly check to see if an updated config.json was delivered via MMS/ESS, then use the value within it to echo hello
while true; do
    
    # check if flows changed
    if [[ $BUILD_MODE == 1 && $OBJECT_RECEIVED == 1 ]]; then

	  ATIME1=`stat -c %Z $DATA/flows.json`
	  ATIME2=`stat -c %Z $DATA/flows_cred.json`

	  if [ ! -e ${DATA}/flows.json ]; then ATIME1="0"; fi
	  if [ ! -e ${DATA}/flows_cred.json ]; then ATIME2="0"; fi
 
	  if [[ "$ATIME1" != "$LTIME1" || "$ATIME2" != "$LTIME2" ]]; then
	  
		LTIME1=$ATIME1
		LTIME2=$ATIME2
		
		if [[ $DEBUG == 1 ]]; then echo "DEBUG: WORKFLOW FILE CHANGE"; fi
		
		DEPLOY_TARGET_HOST=$(ip route|awk '/default/ { print $3 }')
		
		echo $DEPLOY_INITIAL | base64 -d > deployment.json
		
		#HTTP_CODE=$(curl -sSLw "%{http_code}" -o deployment.json ${AUTH} ${CERT} $SOCKET $BASEURL/$DEPLOY_TYPE/$DEPLOY_ID/data) 
		#if [[ "$HTTP_CODE" != '200' && "$HTTP_CODE" != '404' ]]; then echo "Error: HTTP code $HTTP_CODE from: curl -sSLw "%{http_code}" -o deployment.json ${AUTH} ${CERT} $SOCKET $BASEURL/$DEPLOY_TYPE/$DEPLOY_ID/data"; fi
		
		#if [[ $DEBUG == 1 ]]; then echo "DEBUG: RC $HTTP_CODE"; fi		
		#if [[ "$HTTP_CODE" == '200' ]]; then
		if [[ $? == 0 ]]; then
		
			#flows
			content=$(base64 -w 0 $DATA/flows.json)
			new_json=$(jq -c '."flows.json" = $v' --arg v $content deployment.json)
        
			#credentials
			SECRET=$(jq ."_credentialSecret" $DATA/.config.runtime.json -r)
			
			#default
			content64=$(cat $DATA/flows_cred.json | base64 -w 0)
			
			TMP=$(jq 'keys' $DATA/flows_cred.json | jq length)
			if [[ $TMP != 0 ]];then
			  CREDENTIALS=$(jq -r .[keys[0]] $DATA/flows_cred.json)
			
			  content64=$(node /ieam/node-cred $CREDENTIALS $SECRET | base64 -w 0)
			  fi
			  
			new_json=$(echo $new_json | jq -c '."flows_cred.json" = $v' --arg v $content64)
				
			#upload
			#echo "FINAL $new_json"
			if [[ $DEBUG == 1 ]]; then echo "DEBUG: UPLOAD OBJECT TO http://$DEPLOY_TARGET_HOST:$DEPLOY_TARGET_PORT/nodered-upload_deployment/$DEPLOY_TARGET_LINK/data"; fi
			#new_mms=$(echo $new_json | base64 -w 0)
			 
			HTTP_CODE=$(curl -sSLw "%{http_code}" -i -H "Accept: application/json" -H "Content-Type:application/json" -X PUT --data @<(echo $new_json) http://$DEPLOY_TARGET_HOST:$DEPLOY_TARGET_PORT/nodered-upload_deployment/$DEPLOY_TARGET_LINK/data)
			if [[ "$HTTP_CODE" != '200' && "$HTTP_CODE" != '404' ]]; then echo "Error: HTTP code $HTTP_CODE from: curl -sSLw "%{http_code}" -X PUT -d ... http://$DEPLOY_TARGET_HOST:DEPLOY_TARGET_PORT/nodered-upload_deployment/$DEPLOY_TARGET_LINK/data"; fi
			if [[ $DEBUG == 1 ]]; then echo "DEBUG: RC $HTTP_CODE"; fi		
			
			fi
		
		#OBJECT_TYPE_D="deployment-edgenode02_nodered-v2_2.0.5_amd64"
		#OBJECT_ID_D="deploy_ID1619536211331"
		#	
		#HTTP_CODE=$(curl -sSLw "%{http_code}" -o deployment.json ${AUTH} ${CERT} $SOCKET $BASEURL/$OBJECT_TYPE_D/$OBJECT_ID_D/data) 
		#if [[ "$HTTP_CODE" != '200' && "$HTTP_CODE" != '404' ]]; then echo "Error: HTTP code $HTTP_CODE from: curl -sSLw %{http_code} -o deployment.json ${AUTH} ${CERT} $SOCKET $BASEURL/$OBJECT_TYPE_D/$OBJECT_ID_D/data"; fi
		#
		#if [[ $DEBUG == 1 ]]; then echo "DEBUG: RC $HTTP_CODE"; fi		
		#if [[ "$HTTP_CODE" == '200' ]]; then
		#
		#	#flows
		#	content=$(base64 -w 0 $DATA/flows.json)
		#	new_json=$(jq '."flows.json" = $v' --arg v $content deployment.json)
        #
		#	#credentials
		#	SECRET=$(jq ."_credentialSecret" $DATA/.config.runtime.json -r)
		#	
		#	CREDENTIALS=$(jq -r .[keys[0]] $DATA/flows_cred.json);
		#	
		#	content64=$(node /ieam/node-cred $CREDENTIALS $SECRET | base64 -w 0)
		#			
		#	new_json=$(echo $new_json | jq '."flows_cred.json" = $v' --arg v $content64)
		#		
		#	#upload
		#	#echo "FINAL $new_json"
		#	if [[ $DEBUG == 1 ]]; then echo "DEBUG: UPLOAD OBJECT TO MMS"; fi
		#	new_mms=$(echo $new_json | base64 -w 0)
		#	 
		#	HTTP_CODE=$(curl -sSLw "%{http_code}" -X PUT -d $new_mms ${AUTH} ${CERT} $SOCKET $BASEURL/$OBJECT_TYPE_D/$OBJECT_ID_D/data)
		#	if [[ "$HTTP_CODE" != '200' && "$HTTP_CODE" != '404' ]]; then echo "Error: HTTP code $HTTP_CODE from: curl -sSLw %{http_code} -X PUT -d ... ${AUTH} ${CERT} $SOCKET $BASEURL/$OBJECT_TYPE_D/$OBJECT_ID_D/data"; fi
		#	if [[ $DEBUG == 1 ]]; then echo "DEBUG: RC $HTTP_CODE"; fi		
		#	
		#	fi
		fi
	  
    fi

    # See if there is a new version of the config.json file
    if [[ $DEBUG == 1 ]]; then echo "DEBUG: Checking for MMS updates" ; fi   
    HTTP_CODE=$(curl -sSLw "%{http_code}" -o objects.meta ${AUTH} ${CERT} $SOCKET $BASEURL/$OBJECT_TYPE)  # will only get changes that we haven't acknowledged (see below)
    if [[ "$HTTP_CODE" != '200' && "$HTTP_CODE" != '404' ]]; then echo "Error: HTTP code $HTTP_CODE from: curl -sSLw %{http_code} -o objects.meta ${AUTH} ${CERT} $SOCKET $BASEURL/$OBJECT_TYPE"; fi
    if [[ $DEBUG == 1 ]]; then echo "DEBUG: MMS metadata=$(cat objects.meta)"; fi
    
	# objects.meta is a json array of all MMS files of OBJECT_TYPE that have been updated. Search for the ID we are interested in
    OBJ_ID=$(jq -r ".[] | select(.objectID == \"$OBJECT_ID\") | .objectID" objects.meta)  # if not found, jq returns 0 exit code, but blank value

    if [[ "$HTTP_CODE" == '200' && "$OBJ_ID" == $OBJECT_ID ]]; then
        if [[ $DEBUG == 1 ]]; then echo "DEBUG: Received new metadata for $OBJ_ID"; fi

        # Handle the case in which MMS is telling us the config file was deleted
        DELETED=$(jq -r ".[] | select(.objectID == \"$OBJECT_ID\") | .deleted" objects.meta)  # if not found, jq returns 0 exit code, but blank value
        if [[ "$DELETED" == "true" ]]; then
            if [[ $DEBUG == 1 ]]; then echo "DEBUG: MMS file $OBJECT_ID was deleted, reverting to original $OBJECT_ID"; fi

            # Acknowledge that we saw that it was deleted, so it won't keep telling us
            HTTP_CODE=$(curl -sSLw "%{http_code}" -X PUT ${AUTH} ${CERT} $SOCKET $BASEURL/$OBJECT_TYPE/$OBJECT_ID/deleted)
            if [[ "$HTTP_CODE" != '200' && "$HTTP_CODE" != '204' ]]; then echo "Error: HTTP code $HTTP_CODE from: curl -sSLw %{http_code} -X PUT ${AUTH} ${CERT} $SOCKET $BASEURL/$OBJECT_TYPE/$OBJECT_ID/deleted"; fi

            # Revert back to the original config file from the docker image
            cp ${OBJECT_TYPE}.base $OBJECT_TYPE

        else
            
			if [[ $DEBUG == 1 ]]; then echo "DEBUG: Received new/updated $OBJECT_ID from MMS"; fi

            # Read the new file from MMS
            HTTP_CODE=$(curl -sSLw "%{http_code}" -o $OBJECT_TYPE ${AUTH} ${CERT} $SOCKET $BASEURL/$OBJECT_TYPE/$OBJECT_ID/data)
            if [[ "$HTTP_CODE" != '200' ]]; then echo "Error: HTTP code $HTTP_CODE from: curl -sSLw %{http_code} -o $OBJECT_TYPE ${AUTH} ${CERT} $SOCKET $BASEURL/$OBJECT_TYPE/$OBJECT_ID/data"; fi
            #ls -l $OBJECT_ID

            # Acknowledge that we got the new file, so it won't keep telling us
            HTTP_CODE=$(curl -sSLw "%{http_code}" -X PUT ${AUTH} ${CERT} $SOCKET $BASEURL/$OBJECT_TYPE/$OBJECT_ID/received)
            if [[ "$HTTP_CODE" != '200' && "$HTTP_CODE" != '204' ]]; then echo "Error: HTTP code $HTTP_CODE from: curl -sSLw %{http_code} -X PUT ${AUTH} ${CERT} $SOCKET $BASEURL/$OBJECT_TYPE/$OBJECT_ID/received"; fi
        fi

        echo "DEPLOY TARGET START ----------------------"
		
		if [[ $DEBUG == 1 ]]; then echo "DEBUG: pkill node-red";fi
        pkill node-red
        sleep 2
				
		
        if [[ $DEBUG == 1 ]]; then echo "DEBUG: CLEAN ${TEMP}"; fi
        if [ -e ${TEMP} ]; then rm -R ${TEMP}; fi
        mkdir ${TEMP}

        if [[ $DEBUG == 1 ]]; then echo "DEBUG: UNTAR CONFIG"; fi
        tar -xvf $OBJECT_TYPE -C $TEMP
        if [ -e ${TEMP}/settings.js ]; then 
			
			if [[ $DEBUG == 1 ]]; then echo "DEBUG: COPY settings.js to $DATA"; fi
			cp "${TEMP}/settings.js" "$DATA/"
			fi

        if [[ $DEBUG == 1 ]]; then echo "DEBUG: CLEAN EXISTING FLOWS and CREDENTIALS"; fi
        rm $DATA/flows.json
        rm $DATA/flows_cred.json

        su - node-red -c "node-red --userDir /data flows.json" &

        sleep 10

        #call deploy
        if [[ $DEBUG == 1 ]]; then echo "DEBUG: CALL DEPLOY FUNCTION"; fi
	nodered_deploy

	RC=$?

        if [[ $DEBUG == 1 ]]; then echo "DEBUG: DEPLOY RC=$RC"; fi

	if [[ $RC == 0 ]]; then
          
	   if [[ $DEBUG == 1 ]]; then echo "DEBUG: MARK OBJECT RECEIVED AT LEAST ONE TIME"; fi
	   OBJECT_RECEIVED=1

	   if [[ $BUILD_MODE == 1 ]];then
	     
	     if [[ $DEBUG == 1 ]]; then echo "DEBUG: UPDATE STAT FILE  "; fi
  	     LTIME1=`stat -c %Z $DATA/flows.json`
	     LTIME2=`stat -c %Z $DATA/flows_cred.json`
	   fi

	fi 

        echo "DEPLOY TARGET END ------------------------"
    fi

	#BREATHE
    sleep 5
done

