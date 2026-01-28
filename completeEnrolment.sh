#!/bin/zsh -f

# Version
VERSION="1.23"
SCRIPTNAME="$( basename "$0" )"
SERIALNUMBER="$( ioreg -l | grep IOPlatformSerialNumber | cut -d '"' -f 4 )"

# MARK: Commands
# For anything outside /bin /usr/bin, /sbin, /usr/sbin

C_JAMF="/usr/local/bin/jamf"
C_INSTALL="/usr/local/Installomator/Installomator.sh"
C_DIALOG="/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/dialogcli"
C_MKUSER="/usr/local/bin/mkuser"
C_ENROLMENT="/usr/local/bin/completeEnrolment"

checkDialog() {
 if [ ! -e "$C_DIALOG" ]; then
  C_DIALOG="/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog"
 fi
}
checkDialog

# MARK: Variables

DEFAULTS_NAME="completeEnrolment"
# If you change DEFAULTS_NAME, make sure the domain in the config profiles match, or it won't work
DEFAULTS_PLIST="$DEFAULTS_NAME.plist"
LIB="/Library"
PREFS="/private/var/root$LIB/Preferences"
DEFAULTS_BASE="$LIB/Managed Preferences/$DEFAULTS_NAME"
DEFAULTS_FILE="$LIB/Managed Preferences/$DEFAULTS_PLIST"
CLEANUP_FILES=( "$C_ENROLMENT" )
STARTUP_PLIST="$LIB/LaunchDaemons/$DEFAULTS_PLIST"
CLEANUP_FILES+=( "$STARTUP_PLIST" )
LOGIN_PLIST="$LIB/LaunchAgents/$DEFAULTS_PLIST"
CLEANUP_FILES+=( "$LOGIN_PLIST" )
SETTINGS_PLIST="$PREFS/$DEFAULTS_PLIST"
CLEANUP_FILES+=( "$SETTINGS_PLIST" )
CACHE="$LIB/Caches/$DEFAULTS_NAME"
mkdir -p "$CACHE"
CLEANUP_FILES+=( "$CACHE" )
JAMF_URL="$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url )"
JAMF_SERVER="$( echo "$JAMF_URL" | awk -F '(/|:)' '{ print $4 }' )"

# MARK: Whose logged in

# The who command method is used as it is the only one that reliably returns _mbsetupuser as used by
# Setup Assistant, confirming it as the only username logged into the console is the best way to
# identify an ADE/DEP Jamf PreStage Enrollment (after confirming the script was started by Jamf Pro
# with a / in $1).

whoLogged() {
 if [ "$( who | grep console | wc -l )" -gt 1 ]; then
  echo "$( who | grep -v mbsetupuser | grep -m1 console | cut -d " " -f 1 )"
 else
   echo "$( who | grep -m1 console | cut -d " " -f 1 )"
 fi
}

# so we can use ^ for everything other than this matches in case statements
setopt extended_glob

# MARK: prefer jq
if [ -e /usr/bin/jq ]; then
 # jq "alias"
 jq() {
  /usr/bin/jq -eMr ".$1 // empty" "$TRACKER_JSON"
 }
 readJSON() {
  printf '%s' "$1" | /usr/bin/jq -eMr ".$2 // empty"
 }
else
 # makeshift jq replacement
 jq() {
  # JavaScript method can't do key[.otherkey], and doesn't output json format, so must be weary
  #  currently only using listitem[.currentitem].key so we replace .currentitem here with its
  #  contents using sed
  if [[ "$1" == *'[.currentitem'* ]]; then
   local GET_IT="$( echo "$1" | sed "s/\[\.currentitem/[$( jq 'currentitem' )/" )"
  else
   local GET_IT="$1"
  fi
  JSON="$( cat "$TRACKER_JSON" )" osascript -l 'JavaScript' \
   -e 'const env = $.NSProcessInfo.processInfo.environment.objectForKey("JSON").js' \
   -e "JSON.parse(env).$GET_IT"
 }
 readJSON() {
  JSON="$1" osascript -l 'JavaScript' \
   -e 'const env = $.NSProcessInfo.processInfo.environment.objectForKey("JSON").js' \
   -e "JSON.parse(env).$2"
 }
fi

# Log File

# This will Generate a number of log files based on the task and when they started.

LOG_FILE="$LIB/Logs/$DEFAULTS_NAME-$( if [ "$1" = "/" ]; then echo "Jamf" ; else echo "$1" ; fi )-$( whoLogged )-$( date "+%Y-%m-%d %H-%M-%S %Z" ).log"

# MARK: Functions

selfService() {
# The following should work, however in the 11.25.0 beta the self_service_plus_path setting contains the non-plus name ?!?
# SELF_SERVICE="$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path 2>/dev/null )"
# if [ "$SELF_SERVICE" = "" ]; then
#  SELF_SERVICE="$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>/dev/null )"
# fi
# So instead, lets just use the first version of Self Service that appears in the Applications folder.
 ls -d /Applications/* | grep -m1 "Self Service"
}

logIt() {
 echo "$(date) - $@" 2>&1 | tee -a "$LOG_FILE"
}
logIt "###################### completeEnrolment $VERSION started with $1, and $( whoLogged ) is the current console user"

errorIt() {
 logIt "$2" >&2
 logIt "Removing: $CLEANUP_FILES"
 eval "rm -rf $CLEANUP_FILES"
 exit $1
}

defaultRead() {
 local myAttempts=1
 local defaultResult=""
 while [ "$defaultResult" = "" ] && [ $myAttempts -lt 11 ]; do
  defaultResult="$( defaults read "$DEFAULTS_FILE" "$1" 2>/dev/null )"
  echo "$(date) - (Attempt #$myAttempts) Reading Preference $1: $defaultResult" >> "$LOG_FILE"
  ((myAttempts++))
  if [ "$defaultResult" = "" ] && [ $myAttempts -lt 11 ]; then
   sleep 30
  fi
 done
 echo "$defaultResult"
}

defaultReadBool() {
 if [ "$( defaultRead $1 )" = "1" ]; then
  echo "true"
 else
  echo "false"
 fi
}

listRead() {
 plutil -extract "$1" raw -o - "$INSTALLS_JSON" 2>/dev/null
}

settingsPlist() {
 eval "defaults $1 '$SETTINGS_PLIST' '$2' '$3' '$4'" 2>/dev/null
}

readSaved() {
 settingsPlist read "$1" | base64 -d
}

runIt() {
 THE_RETURN="$( eval "$1" 2>&1 )"
 THE_RESULT=$?
 echo "$(date) --- Executed '${2:-"$1"}' which returned signal $THE_RESULT and:\n$THE_RETURN" | tee -a "$LOG_FILE"
 return $THE_RESULT
}

# MARK: mailSend
mailSend() {
 if [ "$EMAIL_AUTH" != "" ] && [ "$( settingsPlist read email )" != "" ] && [[ "$EMAIL_SMTP" = *":"* ]]; then
  logIt "Attempting to send email with details:\nTo be sent via: $EMAIL_SMTP\nFrom: $1\nTo: ${AUTH_SMTP[@]}\nHidden by: $2\nSubject: $3\n\n$4\n"
  curl -s -S --verbose --ssl-reqd --url "smtp://$EMAIL_SMTP" \
     --mail-from "$1" \
     ${AUTH_SMTP[@]} \
     --mail-auth "$EMAIL_AUTH" \
     --user "$EMAIL_AUTH:$( readSaved email )" \
     -T <( echo -e "From: $1\nTo: $2\nSubject: $3\nContent-Type: text/html; charset=\"utf-8\"\nContent-Transfer-Encoding: quoted-printable\n\n<html><body><pre>$4</pre></body></html>" | sed 's/$/\r/' ) 2>&1 | tee -a "$LOG_FILE"
 else
  EMAIL_SMTP_HOST="$( host -t mx "$( echo $2 | cut -d '@' -f 2 )" | head -1 | cut -d ' ' -f 7 ):25"
  if [ "$5" = "" ]; then
   BCCMAIL="$2"
  else
   BCCMAIL="$5"
  fi
  logIt "Attempting to send email with details:\nTo be sent via: $EMAIL_SMTP_HOST\nFrom: $1\nTo: $2\nHidden by: $BCCMAIL\nSubject: $3\n\n$4\n"
  curl -s -S --verbose --url "smtp://$EMAIL_SMTP_HOST" \
    	--mail-from "$1" \
     --mail-rcpt "$2" \
     -T <( echo -e "From: $1\nTo: $BCCMAIL\nSubject: $3\nContent-Type: text/html; charset=\"utf-8\"\nContent-Transfer-Encoding: quoted-printable\n\n<html><body><pre>$4</pre></body></html>" | sed 's/$/\r/' ) 2>&1 | tee -a "$LOG_FILE"
 fi
}

# MARK: subtitleType
subtitleType() {
 case $( jq 'listitem[.currentitem].commandtype' ) in
  selfservice)
   echo "Self Service - $( jq 'listitem[.currentitem].command' )"
  ;;
  policy)
   echo "Jamf Policy - $( jq 'listitem[.currentitem].command' )"
  ;;
  install)
   echo "Installomator Label - $( jq 'listitem[.currentitem].command' )"
  ;;
  jac)
   echo "Jamf App Installer"
  ;;
  mas)
   echo "Mac App Store"
  ;;
  *)
   echo "$( jq 'listitem[.currentitem].command' )"
  ;;
 esac
}

# MARK: infoBox
infoAdd() {
 INFOBOX+="$1  <br><br>"
}
helpAdd() {
 HELPBOX+="$1  <br><br>"
}
bothAdd() {
 infoAdd "$1"
 helpAdd "$( echo "$1" | sed 's/\ <br>//g' )"
}
infoBox() {
 INFOBOX=""
 HELPBOX=""
 helpAdd "$SCRIPTNAME v$VERSION"
 bothAdd "**macOS $( sw_vers -productversion )** on  <br>$( scutil --get ComputerName )  <br>(S/N: $SERIALNUMBER)"
 if [ "$( jq 'startdate' )" != "" ]; then
  bothAdd "**Started:**  <br>$( jq startdate )"
 fi
 if [ "$START_TIME" != "" ]; then
  infoAdd "**Last Restarted:**  <br>$( date -jr "$START_TIME" "+%d/%m/%Y %H:%M %Z" )"
 fi
 if [ "$FINISH_TIME" != "" ]; then
  bothAdd "**Estimated Finish:**  <br>$( date -jr "$FINISH_TIME" "+%d/%m/%Y %H:%M %Z" )"
 fi
 if [ "$FINISHED" != "" ]; then
  bothAdd "**Finished at:**  <br>$( date -jr "$FINISHED" "+%d/%m/%Y %H:%M %Z" )"
 fi
 bothAdd "**Total Tasks:** $( plutil -extract listitem raw -o - "$TRACKER_JSON" )"
 if [ "$1" != "done" ]; then
  if [ "$TASKSLOADING" != "" ]; then
   infoAdd "$TASKSLOADING"
  fi
  infoAdd "**Current Task:** $(($( jq 'currentitem' )+1))  <br>$( jq 'listitem[.currentitem].title' )"
 fi
 if [ "$COUNT" != "" ]; then
  infoAdd "**Attempts/Passes:** $COUNT"
 fi
 if [ "$( jq 'installCount' )" != "" ]; then
  infoAdd "**Install Tasks:** $( jq 'installCount' )"
 fi
 if [ "$SUCCESS_COUNT" != "" ]; then
  if [ "$INFO_SUCCESS_COUNT" = "" ] || [ $SUCCESS_COUNT -gt $INFO_SUCCESS_COUNT ]; then
   INFO_SUCCESS_COUNT=$SUCCESS_COUNT
  fi
  infoAdd "**Installed:** $INFO_SUCCESS_COUNT"
 fi
  if [ "$FAILED_COUNT" != "" ] && [ $FAILED_COUNT -gt 0 ]; then
  bothAdd "**Failed:** $FAILED_COUNT"
 fi
 if [ "$FULLSUCCESS_COUNT" != "" ]; then
  bothAdd "**Completed Tasks:** $FULLSUCCESS_COUNT"
 fi
 track string infobox "$INFOBOX"
 track string helpmessage "$HELPBOX"
 plutil -replace infobox -string "$INFOBOX" "$LOG_JSON"
 plutil -replace helpmessage -string "$HELPBOX" "$LOG_JSON"
 if [ ! -e "$TRACKER_RUNNING" ]; then
  echo "infobox: $INFOBOX" >> "$TRACKER_COMMAND"
  sleep 0.1
  echo "helpmessage: $HELPBOX" >> "$TRACKER_COMMAND"
  sleep 0.1
 fi
 logIt "=== Infobox:\n$INFOBOX"
 logIt "=== Help Message:\n$HELPBOX"
}

# MARK: track
track() {
 local THE_STRING="$( echo "$3" | tr -d '"' )"
 echo "activate:" >> "$TRACKER_COMMAND"
 sleep 0.1
 case $1 in
  bool|integer|string)
   logIt "Updating $2 of type $1 to: $THE_STRING"
   eval "plutil -replace $2 -$1 \"$THE_STRING\" '$TRACKER_JSON'"
   if [ -e "$TRACKER_RUNNING" ]; then
    echo "$2: $THE_STRING" >> "$TRACKER_COMMAND"
    sleep 0.1
   fi
  ;;
  new)
   THE_STRING="$( echo "$2" | tr -d '"' )"
   logIt "Adding task: $THE_STRING"
   eval "plutil -insert listitem -json \"{\\\"title\\\":\\\"$THE_STRING\\\"}\" -append '$TRACKER_JSON'"
   if [ -e "$TRACKER_RUNNING" ]; then
    echo "listitem: add, title: $THE_STRING" >> "$TRACKER_COMMAND"
    sleep 0.1
   fi
   TRACKER_ITEM=${$( jq 'currentitem' ):--1}
   ((TRACKER_ITEM++))
   track integer currentitem $TRACKER_ITEM
   logIt "Added task #$TRACKER_ITEM: $THE_STRING"
  ;;
  update)
   TRACKER_ITEM=${$( jq 'currentitem' ):-0}
   logIt "Updating $2 of task #$TRACKER_ITEM \"$( jq 'listitem[.currentitem].title' )\" to: $THE_STRING"
   eval "plutil -replace listitem.$TRACKER_ITEM.$2 -string \"$THE_STRING\" '$TRACKER_JSON'"
   if [ -e "$TRACKER_RUNNING" ]; then
    echo "listitem: index: $TRACKER_ITEM, $2: $THE_STRING" >> "$TRACKER_COMMAND"
    sleep 0.1
   fi
  ;;
 esac
}

# MARK: testIt, confirms task status
testIt() {
 local RESPONSE
 local ERR_RESPONSE
 case $2 in
  stamp)
   if [ $( date "+%s" ) -ge $(($RECON_DATE+$PER_APP*60)) ]; then
    RECON_DATE=$( date "+%s" )
   fi
  ;&
  date)
   track update statustext "Last Updated - $( date "+%Y-%m-%d %H:%M:%S %Z" )"
  ;|
  pause)
   track update statustext "Resumed"
  ;|
  stamp|date|pause)
   track update status pending
   return 0
  ;;
  *)
   track update statustext "Running Test(s)$THE_COUNT..."
   THE_TEST=false
  ;|
  appstore|teamid)
   if [ "$( eval "ls -d '$3'" 2>/dev/null | wc -l )" -gt 0 ]; then
    CHECKAPP="$( runIt "spctl -a -vv '$3'" )"
    THE_TEST=true
    case $CHECKAPP in
     *'Mac App Store'*)
      RESPONSE="Installed via 'Mac App Store'"
     ;;
     *"($4)"*)
      RESPONSE="Installed and Verified (Team ID $4)"
     ;;
     *)
      RESPONSE="Installed. But Team ID ($4) didn't match (ID $( echo "$CHECKAPP" | awk '/origin=/ { print $NF }' | tr -d '()' ))"
     ;;
    esac
   else
    ERR_RESPONSE="app '$( echo "$3" | sed -E 's=.*/(.*)\.app$=\1=' )' Not Found..."
   fi
  ;|
  result)
   THE_TEST="[ $1 -eq 0 ]"
  ;|
  file)
   THE_TEST="[ -e '$3' ]"
   RESPONSE="Found $3"
   ERR_RESPONSE="$3 Not Found..."
  ;|
  test)
   THE_TEST="$3"
  ;|
  *)
   logIt "Testing with '$THE_TEST'..."
   if eval "$THE_TEST" 2>&1 >> "$LOG_FILE"; then
    track update status success
    if [ "$RESPONSE" = "" ]; then
     track update statustext "Completed"
    else
     track update statustext "$RESPONSE"
    fi
    return 0
   else
    track update status error
    if [ "$ERR_RESPONSE" = "" ]; then
     track update statustext "Test$THE_COUNT Failed..."
    else
     track update statustext "$ERR_RESPONSE"
    fi
    return 1
   fi
  ;;
 esac
}

# MARK: trackIt
# command type (command/policy/label), (shell command, jamf policy trigger, or Installomator label),
#  status confirmation type, file to check for (for test types: file or teamid), Team ID
trackIt() {
 local THE_COUNT=""
 if [ COUNT != "" ]; then
  THE_COUNT=" #$COUNT"
 fi
 case $3 in
  stamp)
   if [ "$RECON_DATE" = "" ]; then
    RECON_DATE=$( date "+%s" )
   elif [ $( date "+%s" ) -lt $(($RECON_DATE+$PER_APP*60)) ]; then
    track update status pending
    return 0
   fi
  ;&
  date)
   track update statustext "Checking..."
  ;;
  pause)
   track update statustext "Paused"
  ;;
  *)
   if ! $( defaultReadBool forceInstall ); then
    testIt 1 $3 $4 $5
    if [ $? -eq 0 ]; then
     return 0
    fi
   fi
   track update statustext "$THE_COUNT Running..."
   sleep 1
  ;;
 esac
 track update status wait
 case $1 in
  command|secure)
   if [[ "$3" != (date|pause|stamp) ]]; then
    track update statustext "Attempt$( if [ "$THE_COUNT" = "" ]; then echo "ing" ; else echo "$THE_COUNT at" ; fi ) the command..."
   fi
  ;|
  secure)
   runIt "$2" "$( echo "$2" | awk -F '(p|P)assword' '{ print $1 }' )... (remainder not logged)"
  ;;
  command)
   runIt "$2"
  ;;
  policy)
   track update statustext "Attempt$( if [ "$THE_COUNT" = "" ]; then echo "ing" ; else echo "$THE_COUNT at" ; fi ) the policy..."
   runIt "$C_JAMF policy -event $2"
  ;;
  install)
   track update statustext "Install attempt$( if [ "$THE_COUNT" = "" ]; then echo " running" ; else echo "$THE_COUNT" ; fi )..."
   MANAGED_OPTIONS="NOTIFY=silent"
   if [ "$GITHUBAPI" != "" ]; then
    MANAGED_OPTIONS+=" $GITHUBAPI"
   fi
   if $( defaultReadBool forceInstall ); then
    MANAGED_OPTIONS+=" INSTALL=force"
   fi
   runIt "$C_INSTALL $2 $MANAGED_OPTIONS"
   unset MANAGED_OPTIONS
  ;;
  jac)
   track update statustext "Waiting for 'Jamf App Installer' to install..."
  ;|
  mas)
   track update statustext "Waiting for 'Mac App Store' to install..."
  ;|
  selfservice)
   if [ "$( jq 'listitem[.currentitem].lastattempt' )" = "" ] || [ $( date "+%s" ) -ge $(($( jq 'listitem[.currentitem].lastattempt' )+$PER_APP*$PER_APP*60)) ]; then
    track update statustext "Asking Self Service to execute..."
    runIt "launchctl asuser $( id -u $( whoLogged ) ) open -j -g -a '$( selfService )' -u '$2'"
    track update lastattempt "$( date "+%s" )"
   else
    track update statustext "Waiting for 'Self Service' to execute..."
   fi
  ;|
  *)
   sleep 30
  ;;
 esac
 testIt $THE_RESULT $3 $4 $5
 return $?
}

# MARK: repeatIt
repeatIt() {
 COUNT=1
 until [ $COUNT -gt $PER_APP ] || trackIt "$1" "$2" "$3" "$4" "$5"; do
  infoBox
  sleep 2
  ((COUNT++))
 done
 if [ $COUNT -gt $PER_APP ]; then
  track update status fail
  track update statustext "Failed after $PER_APP tests"
  unset COUNT
  return 1
 else
  track update status success
  unset COUNT
  return 0
 fi
}

# MARK: trackNew
trackNew() {
 if [ "$( jq 'listitem[.currentitem+1].title' )" = "$1" ]; then
  track integer currentitem $(($( jq 'currentitem' )+1))
 else
  track new "$1"
 fi
 infoBox
}

# title, command type (command/policy/label), (shell command, jamf policy trigger, or Installomator
#  label), subtitle (where command type is secure), status confirmation type, file to check for (for
#  status confirmation type: file)
# MARK: trackNow
trackNow() {
 trackNew "$1"
 if [ "$( jq 'listitem[.currentitem].status' )" = "success" ]; then
  return 0
 else
  local COMMAND_TYPE="$2"
  local COMMAND_NOW="$3"
  case $COMMAND_TYPE in
   secure)
    track update subtitle "$4"
    shift
   ;|
   policy)
    track update subtitle "Jamf Policy - $3"
   ;|
   install)
    track update subtitle "Installomator Label - $3"
   ;|
   ^(policy|install))
    track update subtitle "$3"
   ;|
   *)
    local TEST_TYPE="$4"
    local TEST_NOW="$5"
    local TEST_TEAM=""
    if [ "$TEST_TYPE" = "teamid" ]; then
     TEST_TEAM="$6"
     shift
    fi
    if [ "$6" != "" ]; then
     track update icon "$6"
    fi
    repeatIt "$COMMAND_TYPE" "$COMMAND_NOW" "$TEST_TYPE" "$TEST_NOW" "$TEST_TEAM"
   ;;
  esac
  infoBox
  # Process error here?
  return $THE_RESULT
 fi
}

# MARK: addAdmin: update or add
# $1 = username
# $2 = password
# $3 = name
# $4 = Reference
# $5 = Admin username
# $6 = Admin password
addAdmin() {
 THE_ADMIN="$5"
 THE_PASS="$6"
 MKUSER_OPTIONS="$7"
 if [ "$THE_ADMIN" != "" ]; then
  MKUSER_OPTIONS+=" --secure-token-admin-account-name '$THE_ADMIN' --secure-token-admin-password '$THE_PASS'"
 fi
 if [ "$( whoLogged )" = "$1" ]; then
  trackNow "Resetting password for account $4" \
   secure "sysadminctl -resetPasswordFor '$1' -newPassword '$2' -adminUser '$THE_ADMIN' -adminPassword '$THE_PASS'" "Resetting the password for $1" \
   result '' 'SF=person.fill.checkmark'
  return 0
 fi
 OLD_HOME="$( dscl . read "/Users/$1" NFSHomeDirectory 2>/dev/null | cut -d ' ' -f 2- )"
 if [ "$OLD_HOME" = "" ]; then
  # Account doesn't exist create it
  trackNow "$3 - $4 account" \
   secure "'$C_MKUSER' --username '$1' --password '$2' --real-name '$3' --home '/private/var/$1' --hidden userOnly --skip-setup-assistant firstLoginOnly $ADMIN_ICON --administrator --do-not-confirm --do-not-share-public-folder --prohibit-user-password-changes --prohibit-user-picture-changes $MKUSER_OPTIONS" "Creating username $1" \
   file "/private/var/$1" 'SF=person.badge.plus'
 elif [ "$OLD_HOME" != "/private/var/$1" ]; then
  # Account exists, but it is in the wrong place, move it, and add it's Secure Token
  trackNow "$3 - $4 account" \
   secure "dscl . change '/Users/$1' NFSHomeDirectory '$OLD_HOME' '/private/var/$1' ; mv '$OLD_HOME' '/private/var/$1' ; sysadminctl -secureTokenOn '"$1"' -password '$( readSaved laps )' -adminUser '$THE_ADMIN' -adminPassword '$THE_PASS'" "Moving and securing $1" \
   result '' 'SF=person.badge.plus'
 else
  # Account exists, add it's Secure Token
  trackNow "$3 - $4 account" \
   secure "sysadminctl -secureTokenOn '"$1"' -password '$( readSaved laps )' -adminUser '$THE_ADMIN' -adminPassword '$THE_PASS'" "Securing $1" \
   result '' 'SF=person.badge.plus'
 fi
}


# MARK: Lets get started

caffeinate -dimsuw $$ &

# dono't do anything without a config file
until [ -e "$DEFAULTS_FILE" ]; do
 sleep 1
done

# MARK: Load common settings

PER_APP=${"$( defaultRead perAPP )":-"5"}
DIALOG_ICON="${"$( defaultRead dialogIcon )":-"caution"}"
ADMIN_ICON="${"$( defaultRead adminPicture )":-"--no-picture"}"
if [ "$ADMIN_ICON" != "--no-picture" ]; then
 ADMIN_ICON="--picture '$ADMIN_ICON'"
fi
TRACKER_COMMAND="/tmp/completeEnrolment.DIALOG_COMMANDS.log"
INSTALLS_JSON="$PREFS/completeEnrolment-installs.json"
TRACKER_JSON="$PREFS/completeEnrolment-tracker.json"
LOG_JSON="$PREFS/completeEnrolment-log.json"
TRACKER_RUNNING="/tmp/completeEnrolment.DIALOG.run"
touch "$TRACKER_COMMAND" "$TRACKER_JSON" "$LOG_JSON"
CLEANUP_FILES+=( "$INSTALLS_JSON" )
CLEANUP_FILES+=( "$TRACKER_JSON" )
CLEANUP_FILES+=( "$LOG_JSON" )
TEMP_ADMIN="${"$( defaultRead tempAdmin )":-"setup_admin"}"
TEMP_NAME="${"$( defaultRead tempName )":-"Setup Admin"}"
LAPS_ADMIN="${"$( defaultRead lapsAdmin )":-"laps_admin"}"
LAPS_NAME="${"$( defaultRead lapsName )":-"LAPS Admin"}"

case $1 in
 # MARK: Jamf Enrolment
 /)
  # Install completeEnrolment
  logIt "Installing $C_ENROLMENT..."
  ditto "$0" "$C_ENROLMENT"
  
  # Load & save command line settings from Jamf Pro
  # $4, $5, $6, $7, $8, $9, $10, $11 ?
  # MARK: Load command line settings
  if [ "$4" = "" ]; then
   GITHUBAPI=""
  else
   GITHUBAPI=" GITHUBAPI=$( echo "$4" | base64 -d )"
   settingsPlist write github -string "$4"
  fi
  if [ "$5" = "" ]; then
   TEMP_PASS="$( echo "setup" | base64 )"
  else
   TEMP_PASS="$5"
  fi
  settingsPlist write temp -string "$TEMP_PASS"
  if [ "$6" = "" ]; then
   LAPS_PASS="$TEMP_PASS"
  else
   LAPS_PASS="$6"
  fi
  settingsPlist write laps -string "$LAPS_PASS"
  if [ "$7" = "" ] || [ "$8" = "" ]; then
   if [ "$( whoLogged )" != "_mbsetupuser" ]; then
    "$C_DIALOG" --ontop --icon warning --overlayicon "$DIALOG_ICON" --title none --message "Error: missing Jamf Pro API login details"
   fi
   errorIt 2 "API details are required for access to the \$JAMF_ADMIN password, the following was supplied:\nAPI ID: $7\nAPI Secret: $8"
  else
   settingsPlist write apiId -string "$7"
   settingsPlist write apiSecret -string "$8"
  fi
  settingsPlist write email -string "$9"


  # MARK: Initialise dialog setup file
  #  our "tracker", although plutil can create an empty json, it can't insert into it, incorrectly
  #  mistaking the file to be in another format (OpenStep), so we'll just add an item with an echo
  echo "{\"thisfile\":\"This file was created by completeEnrolment $VERSION\"}" > "$TRACKER_JSON"
  track string title "Welcome to ${"$( defaultRead corpName )":-"The Service Desk"}"
  track string message "Please wait while this computer is set up...<br>Log File available at: $LOG_FILE"
  track string icon "$DIALOG_ICON"
  track string commandfile "$TRACKER_COMMAND"
  track string position "bottom"
  track string height "90%"
  track string width "90%"
  if defaultReadBool appearance; then
   track string appearance dark
  else
   track string appearance light
  fi
  track bool blurscreen true
  ditto "$TRACKER_JSON" "$LOG_JSON"
  plutil -insert listitem -array "$TRACKER_JSON"
  track string liststyle "compact"
  track bool allowSkip true
  plutil -replace displaylog -string "$LOG_FILE" "$LOG_JSON"
  plutil -replace loghistory -integer 1000 "$LOG_JSON"

  # MARK: set time
  TIME_ZONE="${"$( defaultRead systemTimeZone )":-"$( systemsetup -gettimezone | awk "{print \$NF}" )"}"
  trackNow "Setting Time Zone" \
   command "/usr/sbin/systemsetup -settimezone '$TIME_ZONE'" \
   result '' 'SF=clock.badge.exclamationmark'
  sleep 2
  SYSTEM_TIME_SERVER="${"$( defaultRead systemTimeServer )":-"$( systemsetup -getnetworktimeserver | awk "{print \$NF}" )"}"
  trackNow "Setting Network Time Sync server" \
   command "/usr/sbin/systemsetup -setnetworktimeserver '$SYSTEM_TIME_SERVER'" \
   result '' 'SF=clock.badge.questionmark'
  sleep 2
  trackNow "Synchronising the Time" \
   command "/usr/bin/sntp -Ss '$SYSTEM_TIME_SERVER'" \
   result '' 'SF=clock'
  sleep 2
  
  # update infobox
  track string starttime "$( date "+%s" )"
  track string startdate "$( date -jr "$( jq starttime )" "+%d/%m/%Y %H:%M %Z" )"
  infoBox
  
  # MARK: Install Rosetta
  #  (just in case, and skip it for macOS 28+)
  if [ "$( arch )" = "arm64" ] && [ $(sw_vers -productVersion | cut -d '.' -f 1) -lt 28 ]; then
   trackNow "Installing Rosetta for Apple Silicon Mac Intel compatibility" \
    command "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" \
    file "/Library/Apple/usr/libexec/oah/libRosettaRuntime" 'SF=rosette'
   sleep 2
  fi
  
  # MARK: Install initial files
  trackNow "Installing Initial Files" \
   policy "${"$( defaultRead policyInitialFiles )":-"installInitialFiles"}" \
   file "$DIALOG_ICON" 'SF=square.and.arrow.down.on.square'

  # MARK: Install Installomator
  # This can be either the custom version from this repository, or the script that installs the
  # official version.
  trackNow "Installing Installomator" \
   policy "${"$( defaultRead policyInstallomator )":-"installInstallomator"}" \
   file "/usr/local/Installomator/Installomator.sh" 'SF=square.and.arrow.down.badge.checkmark'
  
  # MARK: Install swiftDialog
  trackNow "Installing swiftDialog (the software generating this window)" \
   install dialog \
   teamid "$C_DIALOG" 'PWA5E9TQ59' 'SF=macwindow.badge.plus'
  # set C_DIALOG to match the installed version of dialog
  checkDialog
  
  # Executed by Jamf Pro
  # Load config profile settings and save them for later use in a more secure location, do the same
  # for supplied options such as passwords, only attempt to store them in the Keychain (such as
  # email, and API passwords). This is to allow for hopefully a more secure process, but limiting
  # the access to some of the information to say only during the first 24 hours (at least coming
  # from Jamf Pro that way).
  case $( whoLogged ) in
   # MARK: Prestage Enrolment
   _mbsetupuser)
    # Get setup quickly and start atLoginWindow for initial step tracking followed by a restart.
    # This includes creating a temporary admin account with automatic login status to get the first
    # Secure Token, without which so many things will break.
        
    # Preparing the Login window
    # These settings fix a quirk with automated where the login window instead of having a
    # background, ends up displaying a grey background these two settings apparently repait that.
    runIt "defaults write $LIB/Preferences/com.apple.loginwindow.plist AdminHostInfo -string HostName"
    runIt "defaults write $LIB/Preferences/com.apple.loginwindow.plist SHOWFULLNAME -bool true"
        
    # MARK: Restart the login window
    runIt "/usr/bin/defaults write /Library/Preferences/com.apple.loginwindow.plist LoginwindowText 'Enrolled at $( /usr/bin/profiles status -type enrollment | /usr/bin/grep server | /usr/bin/awk -F '[:/]' '{ print $5 }' )\nplease wait while initial configuration in performed...\nThis computer will restart shortly.'"
    sleep 2
    
    # only kill the login window if it is already running
    if [ "$( pgrep -lu "root" "loginwindow" )" != "" ]; then
     runIt "pkill loginwindow"
    fi

    # MARK: Start dialog on loginwindow
    sleep 2
    defaults write "$LOGIN_PLIST" LimitLoadToSessionType -array "LoginWindow"
    defaults write "$LOGIN_PLIST" Label "$DEFAULTS_NAME.loginwindow"
    defaults write "$LOGIN_PLIST" RunAtLoad -bool TRUE
    defaults write "$LOGIN_PLIST" ProgramArguments -array "$C_DIALOG" "--ontop" \
     "--loginwindow" "--button1disabled" "--button1text" "none" "--jsonfile" "$TRACKER_JSON"
    chmod ugo+r "$LOGIN_PLIST"
    sleep 2
    touch "$TRACKER_RUNNING"
    launchctl load -S LoginWindow "$LOGIN_PLIST"
    sleep 2

    # with a PreStage enrolment, there will be no Apps installed, so we won't allow skipping
    track bool allowSkip false
    
   ;|
   # MARK: Manual (Re-)Enrolment
   ^_mbsetupuser)
    # We will need the login details of a Volume Owner (an account with a Secure Token) to proceed,
    # so we'll ask for it, and in this instance, no need to restart, once the login details are
    # collected, start the dialog and just start processing (after setting the computer name).
    # add completesetup with volume owner details, without automatic login.

    runIt "'$C_ENROLMENT' startDialog >> /dev/null 2>&1 &"

    logIt "Manual or re-enrollment requires login details of a Secure Token enabled account."
 
    # ask for password of someone with a secure token, and promote to admin
    # fdesetup list | cut -d ',' -f 1 | tr '\n' ' '
    # dseditgroup -o edit -a $SECURE_ADMIN -t user admin
    # This is where it gets tricky, as some methods of enrollment are not supposed to interact with the user.
    # A profiles renew -type enrollment is less likely to allow this than a manual enrollment, so some testing will be required.

    TRY_AGAIN=""
    DEMOTE_ADMIN=""
    LOGIN_HEADER="**The login of a Volume Owner (a Secure Token enabled user) is required to complete this enrollment.**\n\n**Please login as a Volume Owner below.**  \n**Current Volume Owners are:**"
    LOGIN_FOOTER="---\n\nNow is a good time to check the computer information is correct, and the following superuser (sudo) terminal commands "
    LOGIN_FOOTER+="can be used to manage Volume Owners (to fix Secure Tokens), in the event the login details for all of the above usernames are unknown:\n\n    fdesetup list  \n"
    LOGIN_FOOTER+="    sysadminctl -secureTokenOn <username> -password - -adminUser <admin> -adminPassword -  \n- _fdesetup_ lists all accounts with Secure Tokens.  \n"
    LOGIN_FOOTER+="- _sysadminctl_ creates the Secure Token after asking for the passwords of the _admin_ and _username_ accounts.  \n    - The _admin_ account must have a Secure Token."
    trackNew "Login Required"
    track update status pending
    track update subtitle "Manual (Re-)Enrolment requires login from a Volume Owner"
    track update statustext "Waiting for successful login..."
    while [ "$SECURE_ADMIN" = "" ]; do
     LOGIN_MESSAGE="$LOGIN_HEADER $( fdesetup list | cut -d ',' -f 1 | tr '\n' ' ' )  \n$TRY_AGAIN\n\n$LOGIN_FOOTER"
     if [ "$TRY_AGAIN" = "" ]; then
      LOGIN_DETAILS="$( "$C_DIALOG" --ontop --title "Enrollment requires login to preceed..." --icon "$DIALOG_ICON" --message "$LOGIN_MESSAGE" --messagefont size=16 --textfield "Username",required,prompt="Please enter a Volume Owner" --textfield "Password",secure,required --json --big 2>>"$LOG_FILE" )"
     else
      LOGIN_DETAILS="$( "$C_DIALOG" --ontop --title "Enrollment requires login to preceed..." --icon warning --overlayicon "$DIALOG_ICON" --message "$LOGIN_MESSAGE" --messagefont size=16 --textfield "Username",required,prompt="Please enter a Volume Owner" --textfield "Password",secure,required --json --big 2>>"$LOG_FILE" )"
     fi
     track update status wait
     A_ADMIN="$( readJSON "$LOGIN_DETAILS" "Username" )"
     A_PASS="$( readJSON "$LOGIN_DETAILS" "Password" )"
     logIt "User is attempting to log into: $A_ADMIN"
     if dscl . -authonly "$A_ADMIN" "$A_PASS" > /dev/null 2>&1 && [ "$( fdesetup list | grep -c "$A_ADMIN" )" -gt 0 ]; then
      logIt "Login successful, and $A_ADMIN has a Secure Token"
      track update status success
      track update statustext "Login Successful"
      SECURE_ADMIN="$A_ADMIN"
      SECURE_PASS="$A_PASS"
      if [ "$( dscl . -read /Groups/admin GroupMembership | cut -d " " -f 2- | grep -c "$A_ADMIN" )" -lt 1 ]; then
       # only give admin if we need to and track it for removal later
       LogIt "Admin access is required. Giving $A_ADMIN temporary admin access."
       track update statustext "Admin access required, elevating temporarily..."
       dseditgroup -o edit -a "$A_ADMIN" -t user admin >> "$LOG_FILE" 2>&1
       DEMOTE_ADMIN="$A_ADMIN"
       # we need this account to be an admin.
      fi
     elif [ "$( fdesetup list | grep -c "$A_ADMIN" )" -gt 0 ]; then
      logIt "Login to $A_ADMIN failed, asking the user to log in again..."
      track update status error
      track update statustest "Password for $A_ADMIN was incorrect"
      TRY_AGAIN="<br>**Password for $A_ADMIN was incorrect.**"
     else
      logIt "Secure Token missing for $A_ADMIN, they are not a Volume Owner, asking the user to log in again..."
      track update status error
      track update statustest "$A_ADMIN is not a Volume Owner, please try one of the listed logins"
      TRY_AGAIN="<br>**$A_ADMIN is not a Volume Owner.**"
     fi
    done
    
    logIt "$SECURE_ADMIN details provided."
    
    # remove (if existing and not logged into) our admin account
    
    # code to be added
    
    
   ;|
   *)
    # MARK: Setup Startup after restart
    trackNow "Add this script to startup process" \
     secure "defaults write '$STARTUP_PLIST' Label '$DEFAULTS_NAME' ; defaults write '$STARTUP_PLIST' RunAtLoad -bool TRUE ; defaults write '$STARTUP_PLIST' ProgramArguments -array '$C_ENROLMENT' ; chmod go+r '$STARTUP_PLIST'" "Creating '$STARTUP_PLIST'" \
     file "$STARTUP_PLIST" 'SF=autostartstop'

    # MARK: Unbind Active Directory
    #  (if bound)
    if [ "$( ls /Library/Preferences/OpenDirectory/Configurations/Active\ Directory | wc -l )" -gt 0 ]; then
     POLICY_UNBIND="$( defaultRead policyADUnbind )"
     if [ "$POLICY_UNBIND" = "" ] || [ "$POLICY_UNBIND" = "force" ]; then
      COMMAND="command"
      POLICY_UNBIND="/usr/sbin/dsconfigad -leave -force"
     else
      COMMAND="policy"
     fi
     trackNow "Unbinding from Active Directory - Required for account management, and computer (re)naming." \
      "$COMMAND" "$POLICY_UNBIND" \
      test '[ "$( ls /Library/Preferences/OpenDirectory/Configurations/Active\ Directory | wc -l )" -eq 0 ]' 'SF=person.2.slash'
    fi

    # MARK: Set the Computer Name
    COMPUTER_NAME="$( scutil --get ComputerName )"
    trackNow "Setting computer name" \
     policy "${"$( defaultRead policyComputerName )":-"fixComputerName"}" \
     test '[ "$COMPUTER_NAME" != "$( scutil --get ComputerName )" ]' 'SF=lock.desktopcomputer'
    infoBox
    
    # MARK: Perform a recon
    #  Helps with scoping install config profiles based on computer name.
    trackNow "Updating Inventory" \
     command "'$C_JAMF' recon" \
     date '' 'SF=list.bullet.rectangle'

    # MARK: Install mkuser
    trackNow "Installing mkuser" \
     install mkuser \
     file "$C_MKUSER" 'SF=person.3.sequence'
    
    # MARK: Add our TEMP_ADMIN
    addAdmin "$TEMP_ADMIN" "$( readSaved temp )" "$TEMP_NAME" "Initial Setup" "$SECURE_ADMIN" "$SECURE_PASS" "--automatic-login"
    
    unset SECURE_ADMIN
    unset SECURE_PASS
    
    if [ "$DEMOTE_ADMIN" != "" ]; then
     logIt "Removing $DEMOTE_ADMIN from Admins group"
     dseditgroup -o edit -d "$DEMOTE_ADMIN" -t user admin >> "$LOG_FILE" 2>&1
    fi
    # Block Self Service macOS Onboarding for TEMP_ADMIN account, we want to use Self Service to
    #  help with installing, and as such can't have Self Service macOS Onboarding getting in the way
    runIt "sudo -u '$TEMP_ADMIN' mkdir -p '/Users/$TEMP_ADMIN/Library/Preferences'"
    runIt "sudo -u '$TEMP_ADMIN' defaults write '/Users/$TEMP_ADMIN/Library/Preferences/com.jamfsoftware.selfservice.mac.plist' 'com.jamfsoftware.selfservice.onboardingcomplete' -bool TRUE"
    runIt "sudo -u '$TEMP_ADMIN' defaults write '/Users/$TEMP_ADMIN/Library/Preferences/com.jamfsoftware.selfserviceplus.plist' 'com.jamfsoftware.selfservice.onboardingcomplete' -bool TRUE"
    runIt "chown '$TEMP_ADMIN' /Users/$TEMP_ADMIN/Library/Preferences/com.jamfsoftware.selfservice*"
   ;|

   _mbsetupuser)
    # MARK: Restart
    #  and record it as a task
    shutdown -r +1 &
    trackNow "Restarting for Application Installation" \
     none 'shutdown -r +1 &' \
     date '' 'SF=restart'
    sleep 5
    rm -rf "$LOGIN_PLIST" "$TRACKER_RUNNING"
   ;;

   *)
    # MARK: Escrow BootStrap Token
    logIt "Escrowing BootStrap Token - required for manual enrolments and re-enrolments."
    EXPECT_SCRIPT="expect -c \""
    EXPECT_SCRIPT+="spawn profiles install -type bootstraptoken ;"
    EXPECT_SCRIPT+=" expect \\\"Enter the admin user name:\\\" ;"
    EXPECT_SCRIPT+=" send \\\"$TEMP_ADMIN\\r\\\" ;"
    EXPECT_SCRIPT+=" expect \\\"Enter the password for user '$TEMP_ADMIN':\\\" ;"
    EXPECT_SCRIPT+=" send \\\"$( readSaved temp )\\r\\\" ;"
    EXPECT_SCRIPT+=" expect \\\"profiles: Bootstrap Token escrowed\\\"\""
    eval "$EXPECT_SCRIPT" >> "$LOG_FILE" 2>&1

    # MARK: Trigger processing
    runIt "'$C_ENROLMENT' process >> /dev/null 2>&1"
   ;;
  esac
  if ${$( defaultReadBool emailJamfLog ):-false} ; then
   # cannot use errorIt to exit here, since 1. this was request, as such, not actually an error, and
   #  2. because errorIt will also cleanUp, which is definitely not wanted at this stage.
   logIt "Exiting with an error signal as requested in the configuration."
   exit 1
  else
   exit 0
  fi
 ;;
 # MARK: Start swiftDialog
 startDialog)
  # to open the event tracking dialog
  TRACKER=true
  echo > "$TRACKER_COMMAND"
  until [[ "$( tail -n1 "$TRACKER_COMMAND" )" = "end:" ]]; do
   if $TRACKER; then
    touch "$TRACKER_RUNNING"
    logIt "Starting Progress Dialog..."
    runIt "'$C_DIALOG' --jsonfile '$TRACKER_JSON' --button1text 'Show Log...'"
    rm -f "$TRACKER_RUNNING"
    TRACKER=false
   else
    logIt "Starting Log view Dialog..."
    runIt "'$C_DIALOG' --jsonfile '$LOG_JSON' --button1text 'Show Tasks...'"
    TRACKER=true
   fi
  done
 ;;
 # MARK: Load saved settings
 *)
  # load saved settings
  if [ "$( settingsPlist read github )" = "" ]; then
   GITHUBAPI=""
  else
   GITHUBAPI=" GITHUBAPI=$( readSaved github )"
  fi
 ;|
 # MARK: Process Installs
 process)
  # clear the LoginwindowText
  runIt "/usr/bin/defaults delete /Library/Preferences/com.apple.loginwindow.plist LoginwindowText"
  # update LOG_JSON to identify and follow the correct log file.
  plutil -replace displaylog -string "$LOG_FILE" "$LOG_JSON"
  track string message "Please wait while this computer is set up...<br>Log File available at: $LOG_FILE"
  plutil -replace message -string "Please wait while this computer is set up...<br>Log File available at: $LOG_FILE" "$LOG_JSON"
  START_TIME=$( date "+%s" )
  infoBox
    
  # MARK: Track Restart
  #  in case of restart in the middle
  if [ "$( jq 'processStart' )" = "" ]; then
   track integer processStart $( jq 'currentitem' )
  else
   track integer currentitem $( jq 'processStart' )
  fi

  # MARK: Wait for Finder & Dock
  while [ "$( pgrep "Finder" )" = "" ] && [ "$( pgrep "Dock" )" = "" ]; do
   sleep 1
  done
    
  sleep 2
  
  # MARK: Close Finder & Dock
  #  if we just started up (i.e. if whoLogged = TEMP_ADMIN)
  if [ "$( whoLogged )" = "$TEMP_ADMIN" ]; then
   track update status success
   launchctl bootout gui/$( id -u $( whoLogged ) )/com.apple.Dock.agent
   launchctl bootout gui/$( id -u $( whoLogged ) )/com.apple.Finder
   sleep 2
  fi
  
  # MARK: Start Tracker dialog
  if [ "$( pgrep "Dialog" )" = "" ]; then
   runIt "'$C_ENROLMENT' startDialog >> /dev/null 2>&1 &"
  fi
  sleep 2
  
  # MARK: Start Self Service
  SELF_SERVICE_NAME="$( echo "$( selfService )" | sed -E 's=.*/(.*)\.app$=\1=' )"
  trackNow "Opening $SELF_SERVICE_NAME" \
   secure "launchctl asuser $( id -u $( whoLogged ) ) open -j -g -a '$( selfService )' ; sleep 5" "$SELF_SERVICE_NAME may be required for some installs" \
   test "[ \"\$( pgrep 'Self Servic(e|e\\+)\$' )\" != '' ]" 'SF=square.and.arrow.down.badge.checkmark'
  sleep 2

  # MARK: Add/update JAMF ADMIN
  # finishing setting up admin accounts
  # Add JSS ADMIN
  # This will load the $JAMF_ADMIN and $JAMF_PASS login details
  JAMF_AUTH_TOKEN="$( readJSON "$( curl -s --location --request POST "${JAMF_URL}api/oauth/token" \
   --header 'Content-Type: application/x-www-form-urlencoded' \
   --data-urlencode "client_id=$( readSaved apiId )" \
   --data-urlencode 'grant_type=client_credentials' \
   --data-urlencode "client_secret=$( readSaved apiSecret )" )" "access_token" )"
  if [ "$JAMF_AUTH_TOKEN" = "" ]; then
   "$C_DIALOG" --ontop --icon warning --overlayicon "$DIALOG_ICON" --title none --message "Error: unable to login to Jamf Pro API"
   errorIt 2 "This should not have happened, are the API ID/Secret details correct?\nResponse from $JAMF_URL:\n$JAMF_AUTH_TOKEN"
  fi
  sleep 1

  JAMF_ACCOUNTS="$( curl -s "${JAMF_URL}api/v2/local-admin-password/$( defaultRead managementID )/accounts" \
   -H "accept: application/json" -H "Authorization: Bearer $JAMF_AUTH_TOKEN" )"
  logIt "Checking for JMF account in:\n$JAMF_ACCOUNTS\n"
  for (( i = 0; i < $( readJSON "$JAMF_ACCOUNTS" "totalCount" ); i++ )); do
   if [ "$( readJSON "$JAMF_ACCOUNTS" "results[$i].userSource" )" = "JMF" ]; then
    JAMF_ADMIN="$( readJSON "$JAMF_ACCOUNTS" "results[$i].username" )"
    JAMF_GUID="$( readJSON "$JAMF_ACCOUNTS" "results[$i].guid" )"
   fi
   if [ "$( readJSON "$JAMF_ACCOUNTS" "results[$i].userSource" )" = "MDM" ]; then
    LAPS_ADMIN="$( readJSON "$JAMF_ACCOUNTS" "results[$i].username" )"
   fi
  done
  logIt "Collected: JAMF_ADMIN = $JAMF_ADMIN, LAPS_ADMIN = $LAPS_ADMIN"
  if [ "$JAMF_ADMIN" = "" ] || [ "$JAMF_GUID" = "" ]; then
   "$C_DIALOG" --ontop --icon warning --overlayicon "$DIALOG_ICON" --title none --message "Error: unable to get management account username from Jamf Pro API"
   errorIt 2 "this should not have happened, unable to get Jamf Managed Account Details:\n$JAMF_AUTH_TOKEN\n$JAMF_ACCOUNTS"
  fi
  sleep 1

  JAMF_PASS="$( readJSON "$( curl -s "${JAMF_URL}api/v2/local-admin-password/$( defaultRead managementID )/account/$JAMF_ADMIN/$JAMF_GUID/password" \
   -H "accept: application/json" -H "Authorization: Bearer $JAMF_AUTH_TOKEN" )" "password" )"
  if [ -z "$JAMF_PASS" ]; then
   "$C_DIALOG" --ontop --icon warning --overlayicon "$DIALOG_ICON" --title none --message "Error: unable to get management account password from Jamf Pro API"
   errorIt 2 "this should not have happened, unable to get Jamf Managed Account Password:\n$JAMF_AUTH_TOKEN\n$JAMF_ACCOUNTS"
  fi

  SECURE_ADMIN="$TEMP_ADMIN"
  SECURE_PASS="$( readSaved temp )"

  addAdmin "$JAMF_ADMIN" "$JAMF_PASS" "$JAMF_ADMIN Account" "Jamf Pro management" "$SECURE_ADMIN" "$SECURE_PASS"

  # MARK: Add/update LAPS ADMIN
  addAdmin "$LAPS_ADMIN" "$( readSaved laps )" "$LAPS_NAME" "Local Administrator" "$SECURE_ADMIN" "$SECURE_PASS"

  unset SECURE_ADMIN
  unset SECURE_PASS
  
  # MARK: Skip install's? (for manual (re-)enrolment)
  if $( jq 'allowSkip' ); then
   trackNew "Install or Skip?"
   track update icon 'SF=questionmark'
   track update status pending
   track update statustext "Asking..."
   track update subtitle "Manual/re-enrolments can decide to skip installing Apps"
   track update status wait
   "$C_DIALOG" --icon "$DIALOG_ICON" --ontop --timer 30 --title none --mini \
    --message "Install Applications?" --button1text "Continue" --button2text "Skip"
   INSTALL_TASKS=$?
   track update status success
  else
   INSTALL_TASKS=0
  fi
  if [ INSTALL_TASKS = 2 ]; then
   track update statustext "Skipped"
  else
   if $( jq 'allowSkip' ); then
    track update statustext "Continuing..."
   fi
   
   # MARK: Prepare Installs

   trackNew "Task List"
   if [ "$( jq 'listitem[.currentitem].status' )" != "success" ]; then
# need to track what has been done better
    track update icon 'SF=checklist'
    track update status pending
    track update statustext "Loading..."
    track update subtitle "Loading the task list(s) from config profile(s)"
    track integer trackitem ${$( jq 'currentitem' ):--1}

    runIt "plutil -convert json -o '$INSTALLS_JSON' '$DEFAULTS_FILE'"
   fi
   THE_TITLE="${"$( /usr/bin/jq -Mr '.name // empty' "$INSTALLS_JSON" )":-"Main"}"
   trackNew "$THE_TITLE"
   if [ "$( jq 'listitem[.currentitem].status' )" != "success" ]; then
    LIST_ICON="${"$( plutil -extract 'taskIcon' raw -o - "$INSTALLS_JSON" )":-"SF=doc.text"}"
    track update icon "$LIST_ICON"
    track update status wait
    track update subtitle "$( /usr/bin/jq -Mr '.subtitle // empty' "$INSTALLS_JSON" )"
    if [ "$( plutil -extract 'installs' raw -o - "$INSTALLS_JSON" 2>/dev/null )" = "" ]; then
     runIt "plutil -insert listitem -array '$INSTALLS_JSON'"
    fi
   fi
   if [ "$( plutil -extract 'installs' raw -o - "$INSTALLS_JSON" 2>/dev/null )" -gt 0 ]; then
    if [ "$( jq 'listitem[.currentitem].status' )" != "success" ]; then
     track update statustext "Loaded"
     track update status success
    fi
    LIST_FILES="$( eval "ls '$DEFAULTS_BASE-'*" 2>/dev/null )"
    logIt "Additional Config Files to load: $LIST_FILES"
    if [ "$( jq 'listitem[.trackitem].status' )" != "success" ]; then
     plutil -replace listitem.$( jq 'trackitem' ).statustext -string "Loading task list(s)..." "$TRACKER_JSON"
     echo "listitem: index: $( jq 'trackitem' ), statustext: Loading task list(s)..." >> "$TRACKER_COMMAND"
    fi
    sleep 0.1
    for LIST_FILE in ${(@f)LIST_FILES} ; do
     logIt "Reading Config File: $LIST_FILE"
     if [ "$( plutil -extract 'installs' raw -o - "$LIST_FILE" 2>/dev/null )" -gt 0 ]; then
      CURRENT_INSTALLS="$( plutil -extract 'installs' raw -o - "$INSTALLS_JSON" 2>/dev/null )"
      THE_TITLE="${"$( plutil -extract 'name' raw -o - "$LIST_FILE" )":-"$( echo "$LIST_FILE" | sed -E "s=^$DEFAULTS_BASE-(.*)\.plist\$=\\1=" )"}"
      TASKSLOADING="**Loading Task List:**  <br>$THE_TITLE..."
      infoBox
      trackNew "$THE_TITLE"
      if [ "$( jq 'listitem[.currentitem].status' )" != "success" ]; then
       track update subtitle "$( plutil -extract 'subtitle' raw -o - "$LIST_FILE" )"
       LIST_ICON="${"$( plutil -extract 'taskIcon' raw -o - "$LIST_FILE" )":-"SF=doc.text"}"
       track update icon "$LIST_ICON"
       track update status wait
       track update statustext "Loading $LIST_FILE..."
       for (( i = 0; i < $( plutil -extract 'installs' raw -o - "$LIST_FILE" 2>dev/null ); i++ )); do
        ADD_THIS="$( plutil -extract "installs.$i" json -o - "$LIST_FILE" )"
        logIt "Adding: $ADD_THIS"
        plutil -insert 'installs' -json "$ADD_THIS" -append "$INSTALLS_JSON"
        logIt "Installs: $( plutil -extract 'installs' raw -o - "$INSTALLS_JSON" 2>/dev/null )"
       done
       if [ $( plutil -extract 'installs' raw -o - "$INSTALLS_JSON" 2>/dev/null ) -gt $CURRENT_INSTALLS ]; then
        track update statustext "Loaded"
        track update status success
       else
        track update statustext "Loading $LIST_FILE failed"
        track update status error
       fi
      fi
     fi
    done
    if [ "$( jq 'listitem[.trackitem].status' )" != "success" ]; then
     plutil -replace listitem.$( jq 'trackitem' ).statustext -string "Config Profile(s) loaded. Loading Tasks..." "$TRACKER_JSON"
     echo "listitem: index: $( jq 'trackitem' ), statustext: Config Profile(s) loaded. Loading Tasks..." >> "$TRACKER_COMMAND"
    fi
    sleep 1
    
    track integer startitem $(($( jq 'currentitem' )+1))
    
    # load software installs
    if [ "$( jq 'listitem[.trackitem].status' )" != "success" ]; then
     track integer 'installCount' 0
     plutil -replace listitem.$( jq 'trackitem' ).status -string "wait" "$TRACKER_JSON"
     echo "listitem: index: $( jq 'trackitem' ), status: wait" >> "$TRACKER_COMMAND"
    fi
    sleep 1

    infoBox
    
    # MARK: Load Installs
    # Cheating by using TRACKER_START to update the Task List loading entry
    plutil -replace listitem.$( jq 'trackitem' ).statustext -string "Loading tasks..." "$TRACKER_JSON"
    echo "listitem: index: $( jq 'trackitem' ), statustext: Loading tasks..." >> "$TRACKER_COMMAND"
    sleep 0.1
    until [ $( jq 'installCount' ) -ge $( listRead 'installs' ) ]; do
     TASKSLOADING="**Loading Install Task:** $(($( jq 'installCount' )+1))"
     infoBox
     # for each item in config profile
     if [ "$( listRead "installs.$( jq 'installCount' ).title" )" != "" ] && [ "$( listRead "installs.$( jq 'installCount' ).commandtype" )" != "" ] ; then
      trackNew "$( listRead "installs.$( jq 'installCount' ).title" )"
      if [ "$( jq 'listitem[.currentitem].status' )" != "success" ]; then
       track update command "$( listRead "installs.$( jq 'installCount' ).command" )"
       track update commandtype "$( listRead "installs.$( jq 'installCount' ).commandtype" )"
       track update suppliedsubtitle "$( listRead "installs.$( jq 'installCount' ).subtitle" )"
       SUBTITLE_TYPE="$( listRead "installs.$( jq 'installCount' ).subtitletype" )"
       if [ "$SUBTITLE_TYPE" = "" ]; then
        track update subtitletype command
       else
        track update subtitletype "$SUBTITLE_TYPE"
       fi
       case "$( jq 'listitem[.currentitem].subtitletype' )" in
        replace|secure)
         track update subtitle "$( jq 'listitem[.currentitem].suppliedsubtitle' )"
        ;;
        command)
         track update subtitle "$( subtitleType )"
        ;;
        combine)
         track update subtitle "$( jq 'listitem[.currentitem].suppliedsubtitle' ) - $( subtitleType )"
        ;;
       esac
       track update successtype "$( listRead "installs.$( jq 'installCount' ).successtype" )"
       track update successtest "$( listRead "installs.$( jq 'installCount' ).successtest" )"
       track update successteam "$( listRead "installs.$( jq 'installCount' ).successteam" )"
       THE_ICON="${"$( listRead "installs.$( jq 'installCount' ).icon" )":-"SF=questionmark.app.dashed"}"
       case $THE_ICON; in
        http*)
         # Cache the icon locally, as scrolling the window causes swiftDialog to reload the icons, which is
         #  not so good when they are hosted, so downloading them to a folder and directing swiftDialog to
         #  the downloaded copy makes much more sense.
         ICON_NAME="$CACHE/$( basename "$THE_ICON" )"
         runIt "curl -sL -o '$ICON_NAME' '$THE_ICON'"
         THE_ICON="$CACHE/icon-$( jq 'installCount' )-$( jq 'currentitem' ).png"
         runIt "sips -s format png '$ICON_NAME' --out '$THE_ICON'"
        ;&
        *)
         track update icon "$THE_ICON"
        ;;
       esac
       
       THE_BACKUPTYPE="$( listRead "installs.$( jq 'installCount' ).backuptype" )"
       if [ "$THE_BACKUPTYPE" = "" ]; then
        track update backuptype 'none'
       else
        track update backuptype "$THE_BACKUPTYPE"
       fi
       track update backupcommand "$( listRead "installs.$( jq 'installCount' ).backupcommand" )"
       track update status pending
       track update statustext "waiting to install..."
      fi
      infoBox
      track integer installCount $(($( jq 'installCount' )+1))
     fi
    done
    TASKSLOADING=""

    if [ "$( jq 'listitem[.trackitem].status' )" != "success" ]; then
     plutil -replace listitem.$( jq 'trackitem' ).statustext -string "Inserting Pause & Inventory Update..." "$TRACKER_JSON"
     echo "listitem: index: $( jq 'trackitem' ), statustext: Inserting Pause & Inventory Update..." >> "$TRACKER_COMMAND"
     sleep 1

     # MARK: Add Pause & Inventory
     trackNew "Pause for 30 seconds"
     if [ "$( jq 'listitem[.currentitem].status' )" != "success" ]; then
      track update icon 'SF=pause.circle'
      track update command "sleep 30"
      track update commandtype none
      track update subtitle "30 second pause for Managed & Self Service tasks"
      track update successtype "pause"
     fi
     sleep 1
     trackNew "Inventory Update"
     if [ "$( jq 'listitem[.currentitem].status' )" != "success" ]; then
      track update icon 'SF=list.bullet.rectangle'
      track update command "'$C_JAMF' recon"
      track update commandtype command
      track update subtitle "Updates inventory once every $PER_APP minutes"
      track update successtype "stamp"
     fi
     infoBox

     sleep 1
    
     plutil -replace listitem.$( jq 'trackitem' ).statustext -string "Loaded" "$TRACKER_JSON"
     echo "listitem: index: $( jq 'trackitem' ), statustext: Loaded" >> "$TRACKER_COMMAND"
     sleep 0.1
     plutil -replace listitem.$( jq 'trackitem' ).status -string "success" "$TRACKER_JSON"
     echo "listitem: index: $( jq 'trackitem' ), status: success" >> "$TRACKER_COMMAND"
     sleep 0.1
    fi
    
    # MARK: Process software installs
    WAIT_TIME=$(($( plutil -extract 'listitem' raw -o - "$TRACKER_JSON" )*$PER_APP*60))
    FINISH_TIME=$(($START_TIME+$WAIT_TIME))
    infoBox
    COUNT=1
    logIt "========================= Process Tasks ========================="
    logIt "Number of Install tasks: $( jq 'installCount' )"
    # On first run, whether restarted or not, test to see if an task has already completed
    # Excludes the result test, as well as date, stamp, and pause
    until [ "$SUCCESS_COUNT" -eq $( jq 'installCount' ) ] || [ $( date "+%s" ) -gt $FINISH_TIME ] || [ "$( jq 'listitem[.currentitem].title' )" = "Checking Status" ]; do
     track integer currentitem $( jq 'startitem' )
     SUCCESS_COUNT=0
     until [ $( jq 'currentitem' ) -ge $( plutil -extract 'listitem' raw -o - "$TRACKER_JSON" ) ] || [ "$( jq 'listitem[.currentitem].title' )" = "Checking Status" ]; do
      logIt "Running Task $( jq 'currentitem' ), SUCCESS_COUNT = $SUCCESS_COUNT"
      infoBox
      if [ "$SUCCESS_COUNT" -eq $( jq 'installCount' ) ]; then
       track update status success
      elif [ "$( jq 'listitem[.currentitem].status' )" != "success" ]; then
       trackIt "$( jq 'listitem[.currentitem].commandtype' )" \
        "$( jq 'listitem[.currentitem].command' )" \
        "$( jq 'listitem[.currentitem].successtype' )" \
        "$( jq 'listitem[.currentitem].successtest' )" \
        "$( jq 'listitem[.currentitem].successteam' )"
       case "$( jq 'listitem[.currentitem].status' )" in
        success)
         ((SUCCESS_COUNT++))
         infoBox
        ;;
        error)
         if [ $COUNT -eq $PER_APP ] && [ "$( jq 'listitem[.currentitem].backuptype' )" != "none" ]; then
          track update commandtype "$( jq 'listitem[.currentitem].backuptype' )"
          track update command "$( jq 'listitem[.currentitem].backupcommand' )"
          case "$( jq 'listitem[.currentitem].subtitletype' )" in
           replace|command)
            track update subtitle "$( subtitleType )"
           ;;
           combine)
            track update subtitle "$( jq 'listitem[.currentitem].suppliedsubtitle' ) - $( subtitleType )"
           ;;
          esac
         fi
        ;;
       esac
       sleep 2
      else
       ((SUCCESS_COUNT++))
       infoBox
       sleep 2
      fi
      track integer currentitem $(($( jq 'currentitem' )+1))
     done
     ((COUNT++))
    done
    track integer currentitem $(($( jq 'currentitem' )-1))
   fi
  fi
  # remove Attempts/Passes from infobox
  unset COUNT

  # MARK: Checking status
  trackNew "Checking Status"
  if [ "$( jq 'listitem[.currentitem].status' )" != "success" ]; then
   track update icon 'SF=checklist'
   track update subtitle "Counting the failed/successful installations"
   track update status wait

   FULLSUCCESS_COUNT=0
   FAILED_COUNT=0
   track integer currentitem 0
   until [ "$( jq 'listitem[.currentitem].title' )" = "Checking Status" ]; do
    case "$( jq 'listitem[.currentitem].status' )" in
     pending)
      track update status success
     ;&
     success)
      ((FULLSUCCESS_COUNT++))
     ;;
     *)
      ((FAILED_COUNT++))
      track update status fail
     ;;
    esac
    track integer currentitem $(($( jq 'currentitem' )+1))
   done
   track update status success
   track update statustext "Checked"
   FINISHED="$( date "+%s" )"
   ((FULLSUCCESS_COUNT++))
   logIt "Success: $FULLSUCCESS_COUNT, Installs: $SUCCESS_COUNT, Failed: $FAILED_COUNT"
  fi
  
  # MARK: Prepare email
  # Time to send email to notify staff to sort out the next step (if necessary).
  trackNew "Emailing Installation Status"
  if [ "$( jq 'listitem[.currentitem].status' )" != "success" ]; then
   track update icon 'SF=mail'
   track update status wait
   track update statustext "Building email content..."
   EMAIL_SUBJECT="$( scutil --get ComputerName ) "
   if [ $FAILED_COUNT -gt 0 ]; then
    EMAIL_SUBJECT+="completed (with some failures)"
   else
    EMAIL_SUBJECT+="successfully completed"
   fi
   EMAIL_SUBJECT+=" $DEFAULTS_NAME from $JAMF_SERVER"
   # swift dialog has issues with :'s and ,'s in the command file
   track update subtitle "$EMAIL_SUBJECT"
   EMAIL_SUBJECT="OSDNotification: $EMAIL_SUBJECT"
   EMAIL_BODY="$( system_profiler SPHardwareDataType | sed -E 's=(Hardware|Overview):(.*)$=\1:<br>=' | sed -E 's=^( *)(.*):(.*)$=<b>\2:</b>\3=' )\n\n"
   NETWORK_INTERFACE="$( route get "$JAMF_SERVER" | grep interface | awk '{ print $NF }' )"
   EMAIL_BODY+="\n<b>MAC Address in use:</b> $( ifconfig "$NETWORK_INTERFACE" | grep ether | awk '{ print $NF }' )\n"
   EMAIL_BODY+="<b>IP Address in use:</b> $( ifconfig "$NETWORK_INTERFACE" | grep "inet " | awk '{ print $2 }' )\n"
   EMAIL_BODY+="<b>On Network Interface:</b> $NETWORK_INTERFACE\n$( networksetup -listnetworkserviceorder | grep -B1 "$NETWORK_INTERFACE" )\n\n"
   EMAIL_BODY+="<b>Software:</b><br>\n<b>macOS Version:</b><br>\n$( sw_vers  | sed -E 's=^( *)(.*):(.*)$=<b>\2:</b>\3=' )\n"
   EMAIL_BODY+="<b>Script:</b> $0\n"
   EMAIL_BODY+="<b>Script Version:</b> $VERSION\n"
   EMAIL_BODY+="<b>Enrollment Started:</b> $( jq startdate )\n"
   EMAIL_BODY+="<b>Last Restart:</b>  $( date -jr "$START_TIME" "+%d/%m/%Y %H:%M %Z" )\n"
   EMAIL_BODY+="<b>Estimated Finish:</b>  $( date -jr "$FINISH_TIME" "+%d/%m/%Y %H:%M %Z" )\n"
   EMAIL_BODY+="<b>Finished at:</b> $( date -jr "$FINISHED" "+%d/%m/%Y %H:%M %Z" )\n"
   EMAIL_BODY+="<b>Total Tasks:</b> $(($( plutil -extract listitem raw -o - "$TRACKER_JSON" )-1))\n"
   EMAIL_BODY+="<b>Apps to Install:</b> $( jq 'installCount' )\n"
   EMAIL_BODY+="<b>Installed:</b> $SUCCESS_COUNT\n"
   EMAIL_BODY+="<b>Failed:</b> $FAILED_COUNT\n"
   EMAIL_BODY+="<b>Completed Tasks:</b> $FULLSUCCESS_COUNT\n"
   LOG_URL="${JAMF_URL}computers.html?id=$( defaultRead jssID )&o=r&v=history"
   EMAIL_BODY+="\nThe initial log is available at: <a href=\"$LOG_URL\">$LOG_URL</a>,\n"
   EMAIL_BODY+="with full logs available in the /Library/Logs folder on the computer.\n"
   EMAIL_BODY+="Please review the logs and contact ${"$( defaultRead serviceName )":-"Service Management"} if any assistance is required.\n\n\n"

   # MARK: Build table
   track integer currentitem 0
   EMAIL_BODY+="<table><tr><td><b>Title</b></td><td><b>Final Status</b></td></tr>\n"
   EMAIL_BODY+="<tr><td><b>Command or Install Type</b></td><td><b>Reason</b></td></tr>\n"
   EMAIL_BODY+="<tr><td>=======================</td><td>============</td></tr>\n"
   until [ $( jq 'currentitem' ) -ge $(($( plutil -extract 'listitem' raw -o - "$TRACKER_JSON" )-1)) ]; do
    EMAIL_BODY+="<tr><td><b>$( jq 'listitem[.currentitem].title' )</b></td><td><b>$( jq 'listitem[.currentitem].status' )</b></td></tr>\n"
    EMAIL_BODY+="<tr><td>$( jq 'listitem[.currentitem].subtitle' )</td><td>$( jq 'listitem[.currentitem].statustext' )</td></tr>\n"
    track integer currentitem $(($( jq 'currentitem' )+1))
   done
   EMAIL_BODY+="</table>"
   
   # MARK: Final preparation of email
   trackupdate statustext "Identifying where to email..."
   EMAIL_FROM="${"$( defaultRead emailFrom )":-""}"
   EMAIL_TO="${"$( defaultRead emailTo )":-""}"
   EMAIL_ERR="${"$( defaultRead emailErrors )":-""}"
   EMAIL_BCC="${"$( defaultRead emailBCC )":-""}"
   EMAIL_HIDDEN="${"$( defaultRead emailBCCFiller )":-"$EMAIL_FROM"}"
   EMAIL_SMTP="${"$( defaultRead emailSMTP )":-""}"
   EMAIL_AUTH="${"$( defaultRead emailAUTH )":-"$EMAIL_FROM"}"
   logIt "Configured Email Details (if being sent):\nTo be sent via: $EMAIL_SMTP\nFrom: $EMAIL_FROM\nTo: $EMAIL_TO\nError: $EMAIL_ERR\nBCC: $EMAIL_BCC\nHidden by: $EMAIL_HIDDEN\nSubject: $EMAIL_SUBJECT\n\n$EMAIL_BODY\n"

   # To help with formatting, and mail client compatibility, html encode all spaces and equals,
   #  except as part of an address tag, in which case restore the space, and the equals should be
   #  quoted-printable encoded (=3D).
   EMAIL_BODY_ENCODED="$( echo "$EMAIL_BODY" | sed -E 's/ /\&nbsp;/g' | sed -E 's/=/\&#x3D;/g' | sed -E 's/\<a\&nbsp;href\&#x3D;/\<a href=3D/g' )"
   
   if [ "$EMAIL_AUTH" != "" ] && [ "$( readSaved email )" != "" ] && [[ "$EMAIL_SMTP" = *":"* ]]; then
    if [ "$EMAIL_FROM" != "" ] && [ "$EMAIL_SUBJECT" != "" ]; then
     logIt "From, and Subject is configured, attempting to send emails"
     AUTH_SMTP=()
     if [ "$EMAIL_TO" != "" ]; then
      logIt "To address configured"
      AUTH_SMTP+=( "--mail-rcpt" )
      AUTH_SMTP+=( "$EMAIL_TO" )
     fi
     if [ "$EMAIL_ERR" != "" ] && [ "$1" -gt 0 ]; then
      logIt "Error address configured"
      AUTH_SMTP+=( "--mail-rcpt" )
      AUTH_SMTP+=( "$EMAIL_ERR" )
     fi
     if [ "$EMAIL_BCC" != "" ]; then
      logIt "BCC address configured"
      AUTH_SMTP+=( "--mail-rcpt" )
      AUTH_SMTP+=( "$EMAIL_BCC" )
     fi
     if [[ "$AUTH_SMTP" = *"--mail-rcpt"* ]]; then
      logIt "Sending email"
      track update statustext "Sending email"
      mailSend "$EMAIL_FROM" "$EMAIL_HIDDEN" "$EMAIL_SUBJECT" "$EMAIL_BODY_ENCODED"
      MAIL_RESULT=$?
     fi
    fi
   else
    if [ "$EMAIL_FROM" != "" ] && [ "$EMAIL_SUBJECT" != "" ]; then
     logIt "From, and Subject is configured, attempting to send emails"
     if [ "$EMAIL_TO" != "" ]; then
      track update statustext "To address configured, sending email"
      mailSend "$EMAIL_FROM" "$EMAIL_TO" "$EMAIL_SUBJECT" "$EMAIL_BODY_ENCODED" "$EMAIL_HIDDEN"
      TO_RESULT=$?
      sleep 5
     fi
     if [ "$EMAIL_ERR" != "" ] && [ "$FAILURE_COUNT" -gt 0 ]; then
      track update statustext "Error address configured, sending email"
      mailSend "$EMAIL_FROM" "$EMAIL_ERR" "$EMAIL_SUBJECT" "$EMAIL_BODY_ENCODED" "$EMAIL_HIDDEN"
      ERR_RESULT=$?
      sleep 5
     fi
     if [ "$EMAIL_BCC" != "" ]; then
      track update statustext "BCC address configured, sending email"
      mailSend "$EMAIL_FROM" "$EMAIL_BCC" "$EMAIL_SUBJECT" "$EMAIL_BODY_ENCODED" "$EMAIL_HIDDEN"
      BCC_RESULT=$?
     fi
    fi
   fi
   
   # MARK: Send email
   if [ "$MAIL_RESULT" -gt 0 ] || [ "$TO_RESULT" -gt 0 ] || [ "$ERR_RESULT" -gt 0 ] || [ "$BCC_RESULT" -gt 0 ]; then
    track update statustext "An email failed to send, see log"
    track update status fail
   else
    track update statustext "Email(s) sent"
    track update status success
   fi
  fi

  # MARK: Connect identidy provider
  #  such as binding to active directory, or setup first user
  trackNow "${"$( defaultRead policyADBindName )":-"Perform Last Steps"}" \
   policy "${"$( defaultRead policyADBind )":-"adBind"}" \
   result '' 'SF=person.text.rectangle'
  
  # MARK: One more recon
  trackNow "Last Inventory Update" \
   secure "'$C_JAMF' recon" "Updates inventory one last time" \
   date '' 'SF=list.bullet.rectangle'
  
  # MARK: Disable automatic login
  #  if our TEMP_ADMIN is still configured
  if [ "$( defaults read /Library/Preferences/com.apple.loginwindow.plist autoLoginUser 2>/dev/null )" = "$TEMP_ADMIN" ]; then
   trackNow "Disable automatic login" \
    secure "defaults delete /Library/Preferences/com.apple.loginwindow.plist autoLoginUser ; rm -f /etc/kcpassword" "Removing $TEMP_ADMIN from automatic login" \
    result '' 'SF=autostartstop.slash'
  elif [ "$( jq 'listitem[.currentitem+1].title' )" = "Disable automatic login" ]; then
   track integer currentitem $(($( jq 'currentitem' )+1))
   if [ "$( jq 'listitem[.currentitem].status' )" != "success" ]; then
    track update status success
   fi
  fi

  # MARK: Shutdown Self Service
  if [ $FAILED_COUNT -eq 0 ]; then
   trackNow "Closing $SELF_SERVICE_NAME" \
    secure "launchctl asuser $( id -u $( whoLogged ) ) osascript -e 'tell app \"$SELF_SERVICE_NAME\" to quit' ; sleep 5" "$SELF_SERVICE_NAME is no longer needed as Installs have completed" \
    test "[ \"\$( pgrep 'Self Servic(e|e\\+)\$' )\" = '' ]" 'SF=square.and.arrow.down.badge.checkmark'
  fi

  # MARK: Finished, what now?
  infoBox done
  COMMAND_FILE="/tmp/finished-$$"
  activateLoop() {
   while [ -e "$COMMAND_FILE" ]; do
    echo "activate:" >> "$COMMAND_FILE"
    sleep 5
   done
  }
  activateLoop &
  "$C_DIALOG" --title "Installation Complete$( if [ $FAILED_COUNT -gt 0 ]; then echo " (with some failures)" ; fi )" --message "Restart, Migrate, or check the logs?" \
   --helpmessage "**Buttons**:  <br>- **View Details** for logs or task list,  \n- Open **Migration Assistant**, or  \n- To log in, **Restart Now**" \
   --infobuttontext "View Details" --button2text "Migration Assistant" --button1text "Restart Now" \
   --icon "$DIALOG_ICON" --iconsize 75 --height 200 --width 500 --commandfile "$COMMAND_FILE"
  case $? in
   *)
    rm -f "$COMMAND_FILE"
   ;|
   0)
    logIt "Restarting..."
    shutdown -r now
   ;;
   *)
    logIt "Removing the blurscreen"
    echo "blurscreen: disable" >> "$TRACKER_COMMAND"
    sleep 0.1
   ;|
   2)
    logIt "Closing the log viewer/task list"
    echo "end:" >> "$TRACKER_COMMAND"
    until [ "$( pgrep "Dialog" )" = "" ]; do
     sleep 1
    done
    logIt "Opening Migration Assistant"
    launchctl asuser $( id -u $( whoLogged ) ) /usr/bin/open /System/Applications/Utilities/Migration\ Assistant.app
   ;;
   3)
    logIt "Leaving the log viewer/task list open for viewing"
   ;|
   ^3)
    logIt "======= How did we get here?!? Log viewer/task list left open"
   ;|
   *)
    logIt "Restarting the Finder & Dock"
    whoId=$( id -u $( whoLogged ) )
    launchctl asuser $whoId launchctl bootstrap gui/$whoId /System/Library/LaunchAgents/com.apple.Finder.plist
    sleep 0.1
    launchctl asuser $whoId launchctl bootstrap gui/$whoId /System/Library/LaunchAgents/com.apple.Dock.plist
    sleep 0.1
    launchctl asuser $whoId launchctl start com.apple.Finder
    sleep 0.1
    launchctl asuser $whoId launchctl start com.apple.Dock.agent
   ;;
  esac
 ;;
 # MARK: Clean up
 cleanUp)
  # A clean up routine
  if ${$( defaultReadBool tempKeep ):-false}; then
   logIt "Keeping $TEMP_ADMIN as requested."
  else
   TEMP_ADMIN_HOME="$( dscl . read "/Users/$TEMP_ADMIN" NFSHomeDirectory | awk -F ': ' '{ print $NF }' )"
   logIt "Removing $TEMP_ADMIN as no longer required."
   runIt "sysadminctl -deleteUser '$TEMP_ADMIN' -adminUser '$TEMP_ADMIN' -adminPassword '$( readSaved laps )'" "Deleting user '$TEMP_ADMIN'"
   if [ -e "$TEMP_ADMIN_HOME" ]; then
    runIt "rm -rf '$TEMP_ADMIN_HOME'" "Removing '$TEMP_ADMIN' home folder: $TEMP_ADMIN_HOME"
   fi
  fi
  logIt "Removing: $CLEANUP_FILES"
  runIt "rm -rf $CLEANUP_FILES"
  logIt "For possible compliance requirement, one more Recon"
  runIt "'$C_JAMF' recon"
 ;;
 # MARK: Default behaviour, clean up or process
 *)
  logIt "TEMP_ADMIN = $TEMP_ADMIN"
  logIt "whoLogged = $( whoLogged )"
  runIt "defaults read /Library/Preferences/com.apple.loginwindow.plist autoLoginUser 2>/dev/null"
  if [ "$( defaults read /Library/Preferences/com.apple.loginwindow.plist autoLoginUser 2>/dev/null )" = "$TEMP_ADMIN" ]; then
   runIt "'$C_ENROLMENT' process >> /dev/null 2>&1"
  else
   runIt "'$C_ENROLMENT' cleanUp >> /dev/null 2>&1"
  fi
 ;;
esac
