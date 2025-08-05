#!/bin/zsh -f

# Version
VERSION="1.0o"

# Commands
# For anything outside /bin /usr/bin, /sbin, /usr/sbin

C_JAMF="/usr/local/bin/jamf"
C_INSTALL="/usr/local/Installomator/Installomator.sh"
C_DIALOG="/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog"
C_MKUSER="/usr/local/bin/mkuser"
C_ENROLMENT="/usr/local/bin/completeEnrolment"

# Variables

DEFAULTS_NAME="completeEnrolment"
# If you change DEFAULTS_NAME, make sure the domain in the config profiles matches, or it won't work
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
CACHE="$LIB/Caches/completeEnrolment"
mkdir -p "$CACHE"
CLEANUP_FILES+=( "$CACHE" )
JAMF_URL="$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist jss_url )"
JAMF_SERVER="$( echo "$JAMF_URL" | awk -F '(/|:)' '{ print $4 }' )"
SELF_SERVICE="$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_plus_path 2>/dev/null )"
if [ "$SELF_SERVICE" = "" ]; then
 SELF_SERVICE="$( defaults read /Library/Preferences/com.jamfsoftware.jamf.plist self_service_app_path 2>/dev/null )"
fi
CPU_ARCH="$( arch )"
TEST_ONLY=false

# Whose logged in

# The who command method is used as it is the only one that reliably returns _mbsetupuser as used by
# Setup Assistant, confirming it as the only username logged into the console is the best way to
# identify an ADE/DEP Jamf PreStage Enrollment (after confirming the script was started by Jamf Pro
# with a / in $1).

if [ "$( who | grep console | wc -l )" -gt 1 ]; then
 WHO_LOGGED="$( who | grep -v mbsetupuser | grep -m1 console | cut -d " " -f 1 )"
else
 WHO_LOGGED="$( who | grep -m1 console | cut -d " " -f 1 )"
fi

# so we can use ^ for everything other than this matches in case statements
setopt extended_glob

# prefer jq
if [ -e /usr/bin/jq ]; then
 # jq "alias"
 jq() {
  /usr/bin/jq -Mr ".$1 // empty" "$TRACKER_JSON"
 }
 readJSON() {
  printf '%s' "$1" | /usr/bin/jq -r ".$2 // empty"
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

LOG_FILE="$LIB/Logs/$DEFAULTS_NAME-$( if [ "$1" = "/" ]; then echo "Jamf" ; else echo "$1" ; fi )-$WHO_LOGGED-$( date "+%Y-%m-%d %H-%M-%S %Z" ).log"

# Functions

errorIt() {
 logIt "$2" >&2
 logIt "Removing: $CLEANUP_FILES"
 eval "rm -rf $CLEANUP_FILES"
 exit $1
}

logIt() {
 echo "$(date) - $@" 2>&1 | tee -a "$LOG_FILE"
}
logIt "###################### completeEnrolment $VERSION started with $1."

defaultRead() {
 defaults read "$DEFAULTS_FILE" "$1" 2>/dev/null
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
 local THE_RESULT="$( eval "$1" 2>&1 )"
 local THE_RETURN=$?
 echo "$(date) --- Executed '${2:-"$1"}' which returned signal $THE_RETURN and:\n$THE_RESULT" | tee -a "$LOG_FILE"
 return $THE_RETURN
}

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

infoBox() {
 INFOBOX="**macOS $( sw_vers -productversion )** on  <br>$( scutil --get ComputerName )  <br><br>"
 INFOBOX+="**Started:**  <br>$( jq startdate )  <br><br>"
 if [ "$START_TIME" != "" ]; then
  INFOBOX+="**Last Restarted:**  <br>$( date -jr "$START_TIME" "+%d/%m/%Y %H:%M %Z" )  <br><br>"
 fi
 if [ "$FINISH_TIME" != "" ]; then
  INFOBOX+="**Estimated Finish:**  <br>$( date -jr "$FINISH_TIME" "+%d/%m/%Y %H:%M %Z" )  <br><br>"
 fi
 if [ "$FINISHED" != "" ]; then
  INFOBOX+="**Finished at:**  <br>$( date -jr "$FINISHED" "+%d/%m/%Y %H:%M %Z" )  <br><br>"
 fi
 INFOBOX+="**Total Tasks:** $( plutil -extract listitem raw -o - "$TRACKER_JSON" )  <br><br>"
 INFOBOX+="**Last Task:** $( jq 'currentitem' )  <br>$( jq 'listitem[.currentitem].title' )  <br><br>"
  if [ "$COUNT" != "" ]; then
  INFOBOX+="**Attempt:** $COUNT  <br><br>"
 fi
 if [ "$( jq 'installCount' )" != "" ]; then
  INFOBOX+="**Install Tasks:** $( jq 'installCount' )  <br><br>"
 fi
 if [ "$SUCCESS_COUNT" != "" ]; then
  INFOBOX+="**Installed:** $SUCCESS_COUNT  <br><br>"
 fi
  if [ "$FAILED_COUNT" != "" ] && [ $FAILED_COUNT -gt 0 ]; then
  INFOBOX+="**Failed:** $FAILED_COUNT  <br><br>"
 fi
 if [ "$FULLSUCCESS_COUNT" != "" ]; then
  INFOBOX+="**Completed Tasks:** $FULLSUCCESS_COUNT  <br><br>"
 fi
 track string infobox "$INFOBOX"
 plutil -replace infobox -string "$INFOBOX" "$LOG_JSON"
 if [ ! -e "$TRACKER_RUNNING" ]; then
  echo "infobox: $INFOBOX" >> "$TRACKER_COMMAND"
  sleep 0.1
 fi
 logIt "$INFOBOX"
}

track() {
 local THE_STRING="$( echo "$3" | tr -d '"' )"
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

# for trackIt and repeatIt:
# command type (command/policy/label), (shell command, jamf policy trigger, or Installomator label),
#  status confirmation type, file to check for (for status confirmation type: file), Team ID
trackIt() {
 track update status wait
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
   track update statustext "$THE_COUNT Running..."
  ;;
 esac
 if ! $TEST_ONLY || [[ "$3" = (result|stamp|date|pause) ]]; then
  case $1 in
   command|secure)
    if [[ "$3" != (date|pause|stamp) ]]; then
     track update statustext "Attempt$( if [ "$THE_COUNT" = "" ]; then echo "ing" ; else echo "$THE_COUNT at" ; fi ) the command..."
    fi
   ;|
   secure)
    runIt "$2" "$( echo "$2" | awk -F '(p|P)assword' '{ print $1 }' )... (hidden)"
   ;;
   command)
    runIt "$2"
   ;;
   policy)
    track update statustext "Attempt$( if [ "$THE_COUNT" = "" ]; then echo "ing" ; else echo "$THE_COUNT at" ; fi ) the policy..."
    runIt "$C_JAMF policy -event $2"
   ;;
   install)
    track update statustext "Attempt$( if [ "$THE_COUNT" = "" ]; then echo "ing" ; else echo "$THE_COUNT at" ; fi ) the install..."
    runIt "$C_INSTALL $2 NOTIFY=silent $GITHUBAPI"
   ;;
   jac)
    track update statustext "Waiting for Jamf App Installer to install..."
   ;|
   mas)
    track update statustext "Waiting for Mac App Store to install..."
   ;|
   selfservice)
    if [ "$( jq 'listitem[.currentitem].lastattempt' )" = "" ] || [ $( date "+%s" ) -ge $(($( jq 'listitem[.currentitem].lastattempt' )+$PER_APP*$PER_APP*30)) ]; then
     track update statustext "Asking Self Service to execute..."
     runIt "launchctl asuser $( id -u $WHO_LOGGED ) open -j -g -a '$SELF_SERVICE' -u '$2'"
     track update lastattempt "$( date "+%s" )"
    else
     track update statustext "Waiting for Self Service to execute..."
    fi
   ;|
   *)
    sleep 30
   ;;
  esac
  THE_RESULT=$?
 fi
 case $3 in
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
   if CHECKAPP="$( spctl -a -vv "$4" 2>&1 )"; then
    THE_TEST=true
    case $CHECKAPP in
     *'Mac App Store'*)
      RESPONSE="Installed via Mac App Store"
     ;;
     *"($5)"*)
      RESPONSE="Installed and Verified (Team ID $5)"
     ;;
     *)
      RESPONSE="Installed, but Team ID ($5) didn't match (ID $( echo "$CHECKAPP" | awk '/origin=/ { print $NF }' | tr -d '()' ))"
     ;;
    esac
   else
    ERR_RESPONSE="App $( echo "$4" | sed -E 's=.*/(.*)\.app$=\1=' ) Not Found..."
   fi
  ;|
  result)
   THE_TEST="[ '$THE_RESULT' -eq 0 ]"
  ;|
  file)
   THE_TEST="[ -e '$4' ]"
   RESPONSE="Found $4"
   ERR_RESPONSE="$4 Not Found..."
  ;|
  test)
   THE_TEST="$4"
  ;|
  *)
   if eval "$THE_TEST" 2>&1 >> "$LOG_FILE"; then
    track update status success
    if [ "$RESPONSE" = "" ]; then
     track update statustext "Completed"
    else
     track update statustext "$RESPONSE"
     unset RESPONSE
    fi
    return 0
   else
    track update status error
    if [ "$ERR_RESPONSE" = "" ]; then
     track update statustext "Test$THE_COUNT Failed..."
    else
     track update statustext "$ERR_RESPONSE"
     unset ERR_RESPONSE
    fi
    return 1
   fi
  ;;
 esac
}

repeatIt() {
 COUNT=1
 until [ $COUNT -gt $PER_APP ] || trackIt "$1" "$2" "$3" "$4"; do
  sleep 5
  ((COUNT++))
 done
 if [ $COUNT -gt $PER_APP ]; then
  track update status fail
  track update statustext "Failed after $PER_APP tests"
  unset COUNT
  return 1
 else
  track update status success
  if [[ "$3" != (date|pause) ]]; then
   track update statustext "Completed"
  fi
  unset COUNT
  return 0
 fi
}

trackNew() {
 if [ "$( jq 'listitem[.currentitem+1].title' )" = "$1" ]; then
  track integer currentitem $(($( jq 'currentitem' )+1))
 else
  track new "$1"
 fi
}

# title, command type (command/policy/label), (shell command, jamf policy trigger, or Installomator
#  label), subtitle (where command type is secure), status confirmation type, file to check for (for
#  status confirmation type: file)
trackNow() {
 trackNew "$1"
 if [ "$( jq 'listitem[.currentitem].status' )" = "success" ]; then
  return 0
 else
  case $2 in
   secure)
    track update subtitle "$4"
    if [ "$7" != "" ]; then
     track update icon "$7"
    fi
    repeatIt "$2" "$3" "$5" "$6"
   ;;
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
    if [ "$6" != "" ]; then
     track update icon "$6"
    fi
    repeatIt "$2" "$3" "$4" "$5"
   ;;
  esac
  THE_RESULT=$?
  # Process error here?
  return $THE_RESULT
 fi
}

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

# Lets get started

caffeinate -dimsuw $$ &

# dono't do anything without a config file
until [ -e "$DEFAULTS_FILE" ]; do
 sleep 1
done

# Load common settings

DIALOG_ICON="${"$( defaultRead dialogIcon )":-"caution"}"
ADMIN_ICON="${"$( defaultRead adminPicture )":-"--no-picture"}"
if [ "$ADMIN_ICON" != "--no-picture" ]; then
 ADMIN_ICON="--picture $ADMIN_ICON"
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
PER_APP=${"$( defaultRead perAPP )":-"5"}

# And start processing

case $1 in
 /)
  # Install completeEnrolment
  logIt "Installing $C_ENROLMENT..."
  ditto "$0" "$C_ENROLMENT"
  
  # Load & save command line settings from Jamf Pro
  # $4, $5, $6, $7, $8, $9, $10, $11 ?
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
   if [ "$WHO_LOGGED" != "_mbsetupuser" ]; then
    "$C_DIALOG" --ontop --icon warning --overlayicon "$DIALOG_ICON" --title none --message "Error: missing Jamf Pro API login details"
   fi
   errorIt 2 "API details are required for access to the \$JAMF_ADMIN password, the following was supplied:\nAPI ID: $7\nAPI Secret: $8"
  else
   settingsPlist write apiId -string "$7"
   settingsPlist write apiSecret -string "$8"
  fi
  settingsPlist write email -string "$9"


  # Initialise dialog setup file, our "tracker"
  # although plutil can create an empty json, it can't insert into it, incorrectly mistaking the
  # file to be in another format (OpenStep), so we'll just add an item with an echo
  echo '{"title":"none"}' > "$TRACKER_JSON"
  track string title "Welcome to ${"$( defaultRead corpName )":-"The Service Desk"}"
  track string message "Please wait while this computer is set up...<br>Log File available at: $LOG_FILE"
  track string icon "$DIALOG_ICON"
  track string commandfile "$TRACKER_COMMAND"
  track string position "bottom"
  track string height "90%"
  track string width "90%"
  track bool blurscreen true
  ditto "$TRACKER_JSON" "$LOG_JSON"
  plutil -insert listitem -array "$TRACKER_JSON"
  track string liststyle "compact"
  plutil -replace displaylog -string "$LOG_FILE" "$LOG_JSON"

  # set time
  TIME_ZONE="${"$( defaultRead systemTimeZone )":-"$( systemsetup -gettimezone | awk "{print \$NF}" )"}"
  trackNow "Setting Time Zone" \
   command "/usr/sbin/systemsetup -settimezone '$TIME_ZONE'" \
   result '' 'SF=clock.badge.exclamationmark'
  sleep 5
  SYSTEM_TIME_SERVER="${"$( defaultRead systemTimeServer )":-"$( systemsetup -getnetworktimeserver | awk "{print \$NF}" )"}"
  trackNow "Setting Network Time Sync server" \
   command "/usr/sbin/systemsetup -setnetworktimeserver '$SYSTEM_TIME_SERVER'" \
   result '' 'SF=clock.badge.questionmark'
  sleep 5
  trackNow "Synchronising the Time" \
   command "/usr/bin/sntp -Ss '$SYSTEM_TIME_SERVER'" \
   result '' 'SF=clock'
  sleep 5
  
  # Load infoBox
  track string starttime "$( date "+%s" )"
  track string startdate "$( date -jr "$( jq starttime )" "+%d/%m/%Y %H:%M %Z" )"
  infoBox
  
  # Install Rosetta (just in case, and skip it for macOS 28+)
  if [ "$CPU_ARCH" = "arm64" ] && [ $(sw_vers -productVersion | cut -d '.' -f 1) -lt 28 ]; then
   trackNow "Installing Rosetta for Apple Silicon Mac Intel compatibility" \
    command "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" \
    file "/Library/Apple/usr/libexec/oah/libRosettaRuntime" 'SF=rosette'
   sleep 5
  fi
  
  # Install initial file
  INSTALL_POLICY="${"$( defaultRead policyInitialFiles )":-"installInitialFiles"}"
  trackNow "Installing Initial Files" \
   policy "$INSTALL_POLICY" \
   file "$DIALOG_ICON" 'SF=square.and.arrow.down.on.square'
  infoBox

  # Install Installomator
  # This can be either the custom version from this repository, or the script that installs the
  # official version.
  INSTALL_POLICY="${"$( defaultRead policyInstallomator )":-"installInstallomator"}"
  trackNow "Installing Installomator" \
   policy "$INSTALL_POLICY" \
   file "/usr/local/Installomator/Installomator.sh" 'SF=square.and.arrow.down.badge.checkmark'
  infoBox
  
  # Install swiftDialog
  trackNow "Installing swiftDialog (the software generating this window)" \
   install dialog \
   file "$C_DIALOG" 'SF=macwindow.badge.plus'
  
  
  # Executed by Jamf Pro
  # Load config profile settings and save them for later use in a more secure location, do the same
  # for supplied options such as passwords, only attempt to store them in the Keychain (such as
  # email, and API passwords). This is to allow for hopefully a more secure process, but limiting
  # the access to some of the information to say only during the first 24 hours (at least coming
  # from Jamf Pro that way).
  case $WHO_LOGGED in
   _mbsetupuser)
    # Get setup quickly and start atLoginWindow for initial step tracking followed by a restart.
    # This includes creating a temporary admin account with automatic login status to get the first
    # Secure Token, without which so many things will break.
        
    # Preparing the Login window
    # These settings fix a quirk with automated where the login window instead of having a
    # background, ends up displaying a grey background these two settings apparently repait that.
    runIt "defaults write $LIB/Preferences/com.apple.loginwindow.plist AdminHostInfo -string HostName"
    runIt "defaults write $LIB/Preferences/com.apple.loginwindow.plist SHOWFULLNAME -bool true"
        
    # Restart the login window
    runIt "/usr/bin/defaults write /Library/Preferences/com.apple.loginwindow.plist LoginwindowText 'Enrolled at $( /usr/bin/profiles status -type enrollment | /usr/bin/grep server | /usr/bin/awk -F '[:/]' '{ print $5 }' )\nplease wait while initial configuration in performed...\nThis computer will restart shortly.'"
    sleep 5
    
    # only kill the login window if it is already running
    if [ "$( pgrep -lu "root" "loginwindow" )" != "" ]; then
     runIt "pkill loginwindow"
    fi

    # start loginwindow
    sleep 2
    defaults write "$LOGIN_PLIST" LimitLoadToSessionType -array "LoginWindow"
    defaults write "$LOGIN_PLIST" Label "$DEFAULTS_NAME.loginwindow"
    defaults write "$LOGIN_PLIST" RunAtLoad -bool TRUE
    defaults write "$LOGIN_PLIST" ProgramArguments -array \
     "/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/Dialog" "--ontop" \
     "--loginwindow" "--button1disabled" "--button1text" "none" "--jsonfile" "$TRACKER_JSON"
    chmod ugo+r "$LOGIN_PLIST"
    sleep 2
    touch "$TRACKER_RUNNING"
    launchctl load -S LoginWindow "$LOGIN_PLIST"
    sleep 2

    MKUSER_OPTIONS=""
   ;|
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

    MKUSER_OPTIONS="--secure-token-admin-account-name '$SECURE_ADMIN' --secure-token-admin-password '$SECURE_PASS'"
    
    # remove (if existing and not logged into) our admin account
    
    # code to be added
    
    
    unset SECURE_PASS
    unset SECURE_ADMIN
   ;|
   *)
    # Setup Startup after restart
    trackNow "Add this script to startup process" \
     secure "defaults write '$STARTUP_PLIST' Label '$DEFAULTS_NAME' ; defaults write '$STARTUP_PLIST' RunAtLoad -bool TRUE ; defaults write '$STARTUP_PLIST' ProgramArguments -array '$C_ENROLMENT' ; chmod go+r '$STARTUP_PLIST'" "Creating '$STARTUP_PLIST'" \
     file "$STARTUP_PLIST" 'SF=autostartstop'

    # unbind from Active Directory (if bound)
    if [ "$( ls /Library/Preferences/OpenDirectory/Configurations/Active\ Directory | wc -l )" -gt 0 ]; then
     POLICY_UNBIND="$( defaultRead policyADUnbind )"
     if [ "$POLICY_UNBIND" = "" ]; then
      COMMAND="command"
      POLICY_UNBIND="/usr/sbin/dsconfigad -leave -force"
     else
      COMMAND="policy"
     fi
     trackNow "Unbinding from Active Directory - Required for account management, and computer (re)naming." \
      "$COMMAND" "$POLICY_UNBIND" \
      test '[ "$( ls /Library/Preferences/OpenDirectory/Configurations/Active\ Directory | wc -l )" -eq 0 ]' 'SF=person.2.slash'
    fi

    # set computername
    INSTALL_POLICY="${"$( defaultRead policyComputerName )":-"fixComputerName"}"
    COMPUTER_NAME="$( scutil --get ComputerName )"
    trackNow "Setting computer name" \
     policy "$INSTALL_POLICY" \
     test '[ "$COMPUTER_NAME" != "$( scutil --get ComputerName )" ]' 'SF=lock.desktopcomputer'
    infoBox
    
    # perform a recon
    trackNow "Updating Inventory" \
     command "'$C_JAMF' recon" \
     date '' 'SF=list.bullet.rectangle'

    # install mkuser
    trackNow "Installing mkuser" \
     install mkuser \
     file "$C_MKUSER" 'SF=person.3.sequence'
    
    # Add complete setup
    trackNow "$TEMP_NAME - Initial Setup account" \
     secure "'$C_MKUSER' --username '$TEMP_ADMIN' --password '$( readSaved temp )' --real-name '$TEMP_NAME' --home /Users/$TEMP_ADMIN --hidden userOnly --skip-setup-assistant firstLoginOnly --automatic-login --no-picture --administrator --do-not-confirm --do-not-share-public-folder --prohibit-user-password-changes --prohibit-user-picture-changes $MKUSER_OPTIONS" "Creating username $TEMP_ADMIN with mkuser" \
     file "/Users/$TEMP_ADMIN" 'SF=person.badge.plus'
    
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
    # Restart, and record it as a task
    shutdown -r +1 &
    trackNow "Restarting for Application Installation" \
     none 'shutdown -r +1 &' \
     date '' 'SF=restart'
    sleep 5
    rm -rf "$LOGIN_PLIST" "$TRACKER_RUNNING"
    # if we get a dialog going, keep it open for at least half the time?
    # sleep 30
   ;;
   *)
    # Escrow BootStrap Token
    logIt "Escrowing BootStrap Token - required for manual enrolments and re-enrolments."
    EXPECT_SCRIPT="expect -c \""
    EXPECT_SCRIPT+="spawn profiles install -type bootstraptoken ;"
    EXPECT_SCRIPT+=" expect \\\"Enter the admin user name:\\\" ;"
    EXPECT_SCRIPT+=" send \\\"$TEMP_ADMIN\\r\\\" ;"
    EXPECT_SCRIPT+=" expect \\\"Enter the password for user '$TEMP_ADMIN':\\\" ;"
    EXPECT_SCRIPT+=" send \\\"$( readSaved temp )\\r\\\" ;"
    EXPECT_SCRIPT+=" expect \\\"profiles: Bootstrap Token escrowed\\\"\""
    eval "$EXPECT_SCRIPT" >> "$LOG_FILE" 2>&1

    # trigger processing
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
 startDialog)
  # to open the event tracking dialog
  TRACKER=true
  echo > "$TRACKER_COMMAND"
  until [[ "$( tail -n1 "$TRACKER_COMMAND" )" = "end:" ]]; do
   if $TRACKER; then
    touch "$TRACKER_RUNNING"
    logIt "Starting Progress Dialog..."
#    runIt "'$C_DIALOG' --loginwindow --jsonfile '$TRACKER_JSON'"
    runIt "'$C_DIALOG' --jsonfile '$TRACKER_JSON' --button1text 'Show Log...'"
    rm -f "$TRACKER_RUNNING"
    TRACKER=false
   else
    logIt "Starting Log view Dialog..."
#    runIt "'$C_DIALOG' --loginwindow --jsonfile '$LOG_JSON'"
    runIt "'$C_DIALOG' --jsonfile '$LOG_JSON' --button1text 'Show Tasks...'"
    TRACKER=true
   fi
   
  done
 ;;
 *)
  # load saved settings
  if [ "$( settingsPlist read github )" = "" ]; then
   GITHUBAPI=""
  else
   GITHUBAPI=" GITHUBAPI=$( readSaved github )"
  fi
 ;|
 process)
  # clear the LoginwindowText
  runIt "/usr/bin/defaults delete /Library/Preferences/com.apple.loginwindow.plist LoginwindowText"
  # update LOG_JSON to identify and follow the correct log file.
  plutil -replace displaylog -string "$LOG_FILE" "$LOG_JSON"
  track string message "Please wait while this computer is set up...<br>Log File available at: $LOG_FILE"
  plutil -replace message -string "Please wait while this computer is set up...<br>Log File available at: $LOG_FILE" "$LOG_JSON"
  START_TIME=$( date "+%s" )
  infoBox
  
  # in case of restart in the middle
  if [ "$( jq 'processStart' )" = "" ]; then
   track integer processStart $( jq 'currentitem' )
  else
   track integer currentitem $( jq 'processStart' )
  fi

  # wait for Finder
  while [ "$( pgrep "Finder" )" = "" ]; do
   sleep 1
  done
  
  # reset WHO_LOGGED as starting before the Finder may have collecting the wrong information
  if [ "$( who | grep console | wc -l )" -gt 1 ]; then
   WHO_LOGGED="$( who | grep -v mbsetupuser | grep -m1 console | cut -d " " -f 1 )"
  else
   WHO_LOGGED="$( who | grep -m1 console | cut -d " " -f 1 )"
  fi
  
  sleep 5
  
  # now is a good time to start Self Service
  launchctl asuser $( id -u $WHO_LOGGED ) osascript -e "tell application \"Finder\" to open POSIX file \"$SELF_SERVICE\""
  sleep 5

  # and close Finder & Dock if we just started up (i.e. if WHO_LOGGED = TEMP_ADMIN)
  if [ "$WHO_LOGGED" = "$TEMP_ADMIN" ]; then
   track update status success
   launchctl bootout gui/$( id -u $WHO_LOGGED )/com.apple.Dock.agent
   launchctl bootout gui/$( id -u $WHO_LOGGED )/com.apple.Finder
   sleep 5
  fi
  
  # Start Tracker dialog
  if [ "$( pgrep -lu "root" "Dialog" )" = "" ]; then
   runIt "'$C_ENROLMENT' startDialog >> /dev/null 2>&1 &"
  fi
  sleep 5
  
  if [ "$( jq 'listitem[.currentitem+1].status' )" != "success" ]; then
    
   # skip this if the computer has been restarted...
   
   # finishing setting up admin accounts
   # Add JSS ADMIN
   # This will load the $JAMF_ADMIN and $JAMF_PASS login details
   JAMF_AUTH_TOKEN="$( echo "$( curl -s --location --request POST "${JAMF_URL}api/oauth/token" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=$( readSaved apiId )" \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode "client_secret=$( readSaved apiSecret )" )" | /usr/bin/jq -Mr ".access_token" )"
   if [[ "$JAMF_AUTH_TOKEN" = *httpStatus* ]]; then
    "$C_DIALOG" --ontop --icon warning --overlayicon "$DIALOG_ICON" --title none --message "Error: unable to login to Jamf Pro API"
    errorIt 2 "This should not have happened, are the API ID/Secret details correct?\nResponse from $JAMF_URL:\n$JAMF_AUTH_TOKEN"
   fi
   sleep 1

   JAMF_ACCOUNTS="$( curl -s "${JAMF_URL}api/v2/local-admin-password/$( defaultRead managementID )/accounts" \
    -H "accept: application/json" -H "Authorization: Bearer $JAMF_AUTH_TOKEN" )"
   logIt "checking for JMF account in:\n$JAMF_ACCOUNTS\n"
   for (( i = 0; i < $( readJSON "$JAMF_ACCOUNTS" "totalCount" ); i++ )); do
    if [ "$( readJSON "$JAMF_ACCOUNTS" "results[$i].userSource" )" = "JMF" ]; then
     JAMF_ADMIN="$( readJSON "$JAMF_ACCOUNTS" "results[$i].username" )"
     JAMF_GUID="$( readJSON "$JAMF_ACCOUNTS" "results[$i].guid" )"
     break
    fi
   done
   if [ -z "$JAMF_ADMIN" ] || [ -z "$JAMF_GUID" ]; then
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
  else
   $JAMF_ADMIN="$( jq 'listitem[.currentitem+1].jssname' )"
  fi

  trackNow "$JAMF_ADMIN - Jamf Pro management account" \
   secure "'$C_MKUSER' --username $JAMF_ADMIN --password '$JAMF_PASS' --real-name '$JAMF_ADMIN Account' --home /private/var/$JAMF_ADMIN --hidden userOnly --skip-setup-assistant firstLoginOnly --no-picture --administrator --do-not-confirm --do-not-share-public-folder --prohibit-user-password-changes --prohibit-user-picture-changes --secure-token-admin-account-name '$TEMP_ADMIN' --secure-token-admin-password '$( readSaved temp )'" "Creating username $JAMF_ADMIN" \
   file "/private/var/$JAMF_ADMIN" 'SF=person.badge.plus'
  track update jssname "$JAMF_ADMIN"
    
  # Add or update LAPS ADMIN
  if [ -e "/Users/$LAPS_ADMIN" ]; then
   trackNow "$LAPS_NAME - Local Administrator account" \
    secure "dscl . change '/Users/$LAPS_ADMIN' NFSHomeDirectory '/Users/$LAPS_ADMIN' '/private/var/$LAPS_ADMIN' ; mv '/Users/$LAPS_ADMIN' '/private/var/$LAPS_ADMIN' ; sysadminctl -secureTokenOn '"$LAPS_ADMIN"' -password '$( readSaved laps )' -adminUser '$TEMP_ADMIN' -adminPassword '$( readSaved temp )'" "Moving and securing $LAPS_ADMIN"\
    result '' 'SF=person.badge.plus'

  else
   trackNow "$LAPS_NAME - Local Administrator account" \
    secure "'$C_MKUSER' --username $LAPS_ADMIN --password '$( readSaved laps )' --real-name '$LAPS_NAME' --home /private/var/$LAPS_ADMIN --hidden userOnly --skip-setup-assistant firstLoginOnly --no-picture --administrator --do-not-confirm --do-not-share-public-folder --prohibit-user-password-changes --prohibit-user-picture-changes --secure-token-admin-account-name '$TEMP_ADMIN' --secure-token-admin-password '$( readSaved temp )'" "Creating username $LAPS_ADMIN" \
    file "/private/var/$LAPS_ADMIN" 'SF=person.badge.plus'
  fi
  
  # Allow for multiple install lists, to help provide better scoping of base and specific app
  #  installs, with reduced replication, such that the base apps will not be required in all install
  #  list variations.

  trackNew "Task List"
  track update icon 'SF=checklist'
  track update status pending
  track update statustext "Loading..."
  track update subtitle "Loading the task list(s) from config profile(s)"
  track integer trackitem ${$( jq 'currentitem' ):--1}

  runIt "plutil -convert json -o '$INSTALLS_JSON' '$DEFAULTS_FILE'"
  THE_TITLE="$( /usr/bin/jq -Mr '.name // empty' "$INSTALLS_JSON" )"
  if [ "$THE_TITLE" = "" ]; then
   THE_TITLE="Main"
  fi
  trackNew "$THE_TITLE"
  track update icon 'SF=doc.text'
  track update status wait
  track update subtitle "$( /usr/bin/jq -Mr '.subtitle // empty' "$INSTALLS_JSON" )"
  if [ "$( plutil -extract 'installs' raw -o - "$INSTALLS_JSON" 2>/dev/null )" = "" ]; then
   runIt "plutil -insert listitem -array '$INSTALLS_JSON'"
  fi
  if [ "$( plutil -extract 'installs' raw -o - "$INSTALLS_JSON" 2>/dev/null )" -gt 0 ]; then
   track update statustext "Loaded"
   track update status success
   LIST_FILES="$( eval "ls '$DEFAULTS_BASE-'*" 2>/dev/null )"
   logIt "Additional Config Files to load: $LIST_FILES"
   for LIST_FILE in ${(@f)LIST_FILES} ; do
    logIt "Reading Config File: $LIST_FILE"
    if [ "$( plutil -extract 'installs' raw -o - "$LIST_FILE" 2>/dev/null )" -gt 0 ]; then
     CURRENT_INSTALLS="$( plutil -extract 'installs' raw -o - "$INSTALLS_JSON" 2>/dev/null )"
     THE_TITLE="$( plutil -extract 'name' raw -o - "$LIST_FILE" )"
     if [ "$THE_TITLE" = "" ]; then
      THE_TITLE="$( echo "$LIST_FILE" | sed -E "s=^$DEFAULTS_BASE-(.*)\.plist\$=\\1=" )"
     fi
     plutil -replace listitem.$( jq 'trackitem' ).statustext -string "Loading task list $THE_TITLE..." "$TRACKER_JSON"
     echo "listitem: index: $( jq 'trackitem' ), statustext: Loading task list $THE_TITLE..." >> "$TRACKER_COMMAND"
     sleep 0.1
     trackNew "$THE_TITLE"
     if [ "$( jq 'listitem[.currentitem].status' )" != "success" ]; then
      track update subtitle "$( plutil -extract 'subtitle' raw -o - "$INSTALLS_JSON" )"
      track update icon 'SF=doc.text'
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
   plutil -replace listitem.$( jq 'trackitem' ).statustext -string "Config Profile(s) loaded. Loading Tasks..." "$TRACKER_JSON"
   echo "listitem: index: $( jq 'trackitem' ), statustext: Config Profile(s) loaded. Loading Tasks..." >> "$TRACKER_COMMAND"
   sleep 1
   
   track integer startitem $(($( jq 'currentitem' )+1))
   
   # load software installs
   track integer 'installCount' 0
   plutil -replace listitem.$( jq 'trackitem' ).status -string "wait" "$TRACKER_JSON"
   echo "listitem: index: $( jq 'trackitem' ), status: wait" >> "$TRACKER_COMMAND"
   sleep 1

   infoBox
   
   until [ $( jq 'installCount' ) -ge $( listRead 'installs' ) ]; do
    
    # Cheating by using TRACKER_START to update the Task List loading entry
    plutil -replace listitem.$( jq 'trackitem' ).statustext -string "Loading task #$(($( jq 'installCount' )+1))" "$TRACKER_JSON"
    echo "listitem: index: $( jq 'trackitem' ), statustext: Loading task #$(($( jq 'installCount' )+1))" >> "$TRACKER_COMMAND"
    sleep 0.1
    
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
      THE_ICON="$( listRead "installs.$( jq 'installCount' ).icon" )"
      if [ "$THE_ICON" = "" ]; then
       track update icon none
      else
       case $THE_ICON; in
        http*)
         # Cache the icon locally, as scrolling the window causes swiftDialog to reload the icons, which is
         #  not so good when they are hosted, so downloading them to a folder and directing swiftDialog to
         #  the downloaded copy makes much more sense.
         ICON_NAME="$CACHE/$( basename "$THE_ICON" )"
         runIt "curl -s -o '$ICON_NAME' '$THE_ICON'"
         THE_ICON="$CACHE/icon-$( jq 'installCount' )-$( jq 'currentitem' ).png"
         runIt "sips -s format png '$ICON_NAME' --out '$THE_ICON'"
        ;&
        *)
         track update icon "$THE_ICON"
        ;;
       esac
      fi
      
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

   plutil -replace listitem.$( jq 'trackitem' ).statustext -string "Inserting Pause & Inventory Update..." "$TRACKER_JSON"
   echo "listitem: index: $( jq 'trackitem' ), statustext: Inserting Pause & Inventory Update..." >> "$TRACKER_COMMAND"
   sleep 1

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
   
   sleep 1
   
   plutil -replace listitem.$( jq 'trackitem' ).statustext -string "Loaded" "$TRACKER_JSON"
   echo "listitem: index: $( jq 'trackitem' ), statustext: Loaded" >> "$TRACKER_COMMAND"
   sleep 0.1
   plutil -replace listitem.$( jq 'trackitem' ).status -string "success" "$TRACKER_JSON"
   echo "listitem: index: $( jq 'trackitem' ), status: success" >> "$TRACKER_COMMAND"
   sleep 0.1
   
   # process software installs
   WAIT_TIME=$(($( plutil -extract 'listitem' raw -o - "$TRACKER_JSON" )*$PER_APP*60))
   FINISH_TIME=$(($START_TIME+$WAIT_TIME))
   infoBox
   COUNT=1
   logIt "========================= Process Tasks ========================="
   logIt "Number of Install tasks: $( jq 'installCount' )"
   # On first run, whether restarted or not, test to see if an task has already completed
   # Excludes the result test, as well as date, stamp, and pause
   TEST_ONLY=true
   until [ "$SUCCESS_COUNT" -eq $( jq 'installCount' ) ] || [ $( date "+%s" ) -gt $FINISH_TIME ]; do
    track integer currentitem $( jq 'startitem' )
    SUCCESS_COUNT=0
    until [ $( jq 'currentitem' ) -ge $( plutil -extract 'listitem' raw -o - "$TRACKER_JSON" ) ]; do
     logIt "Running Task $( jq 'currentitem' ), SUCCESS_COUNT = $SUCCESS_COUNT"
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
    TEST_ONLY=false
    ((COUNT++))
   done
   track integer currentitem $(($( jq 'currentitem' )-1))
  fi

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
  infoBox
  
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
   EMAIL_BODY="$( system_profiler SPHardwareDataType | sed -E 's=^( *)(.*):(.*)$=<b>\2:</b>\3=' )\n"
   NETWORK_INTERFACE="$( route get "$JAMF_SERVER" | grep interface | awk '{ print $NF }' )"
   EMAIL_BODY+="\n<b>MAC Address in use:</b> $( ifconfig "$NETWORK_INTERFACE" | grep ether | awk '{ print $NF }' )\n"
   EMAIL_BODY+="<b>IP Address in use:</b> $( ifconfig "$NETWORK_INTERFACE" | grep "inet " | awk '{ print $2 }' )\n"
   EMAIL_BODY+="<b>On Network Interface:</b> $NETWORK_INTERFACE\n$( networksetup -listnetworkserviceorder | grep -B1 "$NETWORK_INTERFACE" )\n\n"
   EMAIL_BODY+="<b>Script:</b> $0\n"
   EMAIL_BODY+="<b>Enrollment Started:</b> $( jq startdate )\n"
   EMAIL_BODY+="<b>Last Restart:</b>  $( date -jr "$START_TIME" "+%d/%m/%Y %H:%M %Z" )\n"
   EMAIL_BODY+="<b>Estimated Finish:</b>  $( date -jr "$FINISH_TIME" "+%d/%m/%Y %H:%M %Z" )\n"
   EMAIL_BODY+="<b>Finished at:</b> $( date -jr "$FINISHED" "+%d/%m/%Y %H:%M %Z" )\n"
   EMAIL_BODY+="<b>Total Tasks:</b> $( plutil -extract listitem raw -o - "$TRACK_JSON" )\n"
   EMAIL_BODY+="<b>Apps to Install:</b> $( jq 'installCount' )\n"
   EMAIL_BODY+="<b>Installed:</b> $SUCCESS_COUNT\n"
   EMAIL_BODY+="<b>Failed:</b> $FAILED_COUNT\n"
   EMAIL_BODY+="<b>Completed Tasks:</b> $FULLSUCCESS_COUNT\n"
   EMAIL_BODY+="\nThe initial log is available at: "
   EMAIL_BODY+="<a href=\"${JAMF_URL}computers.html?id=$( defaultRead jssID )&o=r&v=history\">${JAMF_URL}computers.html?id=$( defaultRead jssID )&o=r&v=history</a>,\n"
   EMAIL_BODY+="with full logs available in the /Library/Logs folder on the computer.\n"
   EMAIL_BODY+="Please review the logs and contact ${"$( defaultRead serviceName )":-"Service Management"} if any assistance is required.\n\n\n"

   track integer currentitem 0
   EMAIL_BODY+="<table><tr><td><b>Title</b></td><td><b>Final&nbsp;Status</b></td></tr>\n"
   EMAIL_BODY+="<tr><td><b>Command&nbsp;or&nbsp;Install&nbsp;Type</b></td><td><b>Reason</b></td></tr>\n"
   EMAIL_BODY+="<table><tr><td>=======================</td><td>============</td></tr><\n"
   until [ $( jq 'currentitem' ) -ge $(($( plutil -extract 'listitem' raw -o - "$TRACKER_JSON" )-1)) ]; do
    EMAIL_BODY+="<tr><td><b>$( jq 'listitem[.currentitem].title' )</b></td><td><b>Final Status: $( jq 'listitem[.currentitem].status' )</b></td></tr>\n"
    EMAIL_BODY+="<tr><td>$( jq 'listitem[.currentitem].subtitle' )</td><td>$( jq 'listitem[.currentitem].statustext' )</td></tr>\n"
    track integer currentitem $(($( jq 'currentitem' )+1))
   done
   EMAIL_BODY+="</table>"
   
   trackupdate statustext "Identifying where to email..."
   EMAIL_FROM="${"$( defaultRead emailFrom )":-""}"
   EMAIL_TO="${"$( defaultRead emailTo )":-""}"
   EMAIL_ERR="${"$( defaultRead emailErrors )":-""}"
   EMAIL_BCC="${"$( defaultRead emailBCC )":-""}"
   EMAIL_HIDDEN="${"$( defaultRead emailBCCFiller )":-"$EMAIL_FROM"}"
   EMAIL_SMTP="${"$( defaultRead emailSMTP )":-""}"
   EMAIL_AUTH="${"$( defaultRead emailAUTH )":-"$EMAIL_FROM"}"
   logIt "Configured Email Details (if being sent):\nTo be sent via: $EMAIL_SMTP\nFrom: $EMAIL_FROM\nTo: $EMAIL_TO\nError: $EMAIL_ERR\nBCC: $EMAIL_BCC\nHidden by: $EMAIL_HIDDEN\nSubject: $EMAIL_SUBJECT\n\n$EMAIL_BODY\n"

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
      mailSend "$EMAIL_FROM" "$EMAIL_HIDDEN" "$EMAIL_SUBJECT" "$EMAIL_BODY"
      MAIL_RESULT=$?
     fi
    fi
   else
    if [ "$EMAIL_FROM" != "" ] && [ "$EMAIL_SUBJECT" != "" ]; then
     logIt "From, and Subject is configured, attempting to send emails"
     if [ "$EMAIL_TO" != "" ]; then
      track update statustext "To address configured, sending email"
      mailSend "$EMAIL_FROM" "$EMAIL_TO" "$EMAIL_SUBJECT" "$EMAIL_BODY" "$EMAIL_HIDDEN"
      TO_RESULT=$?
      sleep 5
     fi
     if [ "$EMAIL_ERR" != "" ] && [ "$FAILURE_COUNT" -gt 0 ]; then
      track update statustext "Error address configured, sending email"
      mailSend "$EMAIL_FROM" "$EMAIL_ERR" "$EMAIL_SUBJECT" "$EMAIL_BODY" "$EMAIL_HIDDEN"
      ERR_RESULT=$?
      sleep 5
     fi
     if [ "$EMAIL_BCC" != "" ]; then
      track update statustext "BCC address configured, sending email"
      mailSend "$EMAIL_FROM" "$EMAIL_BCC" "$EMAIL_SUBJECT" "$EMAIL_BODY" "$EMAIL_HIDDEN"
      BCC_RESULT=$?
     fi
    fi
   fi
   
   if [ "$MAIL_RESULT" -gt 0 ] || [ "$TO_RESULT" -gt 0 ] || [ "$ERR_RESULT" -gt 0 ] || [ "$BCC_RESULT" -gt 0 ]; then
    track update statustext "An email failed to send, see log"
    track update status fail
   else
    track update statustext "Email(s) sent"
    track update status success
   fi
  fi

  # disable automatic login if our TEMP_ADMIN is still configured
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

  # connect identidy provider or bind to active directory
  trackNow "Attaching Identity Provider (or Active Directory binding)" \
   policy "${"$( defaultRead policyADBind )":-"adBind"}" \
   result '' 'SF=person.text.rectangle'
  
  # one more recon
  trackNow "Last Inventory Update" \
   secure "'$C_JAMF' recon" "Updates inventory one last time" \
   date '' 'SF=list.bullet.rectangle'
  
  # Wait for user
#  plutil -replace button2text "Finish" "$TRACKER_JSON"
#  plutil -replace button2text "Finish" "$LOG_JSON"
  echo "button1text: Finish" >> "$TRACKER_COMMAND"
  sleep 0.1
  echo "end:" >> "$TRACKER_COMMAND"
  
  # wait for dialog to close
  until [ "$( pgrep "Dialog" )" = "" ]; do
   sleep 1
  done
  
 ;;
 cleanUp)
  # A clean up routine
  if ${$( defaultReadBool tempKeep ):-false}; then
   TEMP_ADMIN="${"$( defaultRead tempAdmin )":-"setup_admin"}"
   logIt "Removing $TEMP_ADMIN as no longer required."
   runIt "sysadminctl -deleteUser '$TEMP_ADMIN' -adminUser '$TEMP_ADMIN' -adminPassword '$( readSaved laps )'" "Delete user '$TEMP_ADMIN'"
  fi
  logIt "Removing: $CLEANUP_FILES"
  eval "rm -rf $CLEANUP_FILES"
 ;;
 *)
  logIt "TEMP_ADMIN = $TEMP_ADMIN"
  logIt "WHO_LOGGED = $WHO_LOGGED"
  runIt "defaults read /Library/Preferences/com.apple.loginwindow.plist autoLoginUser 2>/dev/null"
  if [ "$( defaults read /Library/Preferences/com.apple.loginwindow.plist autoLoginUser 2>/dev/null )" = "$TEMP_ADMIN" ]; then
   runIt "'$C_ENROLMENT' process >> /dev/null 2>&1"
  else
   runIt "'$C_ENROLMENT' cleanUp >> /dev/null 2>&1"
  fi
 ;;
esac
