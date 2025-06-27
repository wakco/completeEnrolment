#!/bin/zsh -f

# Whose logged in

# The who command method is used as it is the only one that still returns _mbsetupuser as used by
# Setup Assistant, confirming it as the only username logged into the console is the best way to
# identify a ADE/DEP Jamf PreStage Enrollment (after confirming the script was started by Jamf Pro
# with a / in $1).

if [ "$( who | grep console | wc -l )" -gt 1 ]; then
 WHO_LOGGED="$( who | grep -v mbsetupuser | grep -m1 console | cut -d " " -f 1 )"
else
 WHO_LOGGED="$( who | grep -m1 console | cut -d " " -f 1 )"
fi

case $1 in
 /)
  # Executed by Jamf Pro
  case $WHO_LOGGED in
   _mbsetupuser)
    # Get setup quickly and start atLoginWindow for initial step tracking followed by a restart.
    # This includes creating a temporary admin account with automatic login status to get the first
    # Secure Token, without which so many things will break.
   ;;
   *)
    # We will need the logins of an account with a Secure Token to proceed, so lets ask
    # In this instance, no need to restart, once the login details are collected, just start processing.
   ;;
  esac
 ;;
 atLoginWindow)
  # triggered loginwindow
 ;; # or ;& ?
 startProcessing)
 ;; # or ;& ?
 continueProcessing)
 ;;
 atRestart)
  # continued processing, possibly after restarting?
 ;;
 cleanUp)
  # A clean up routine
 ;;
 emailError)
 ;; # ?
 emailSuccess)
 ;; # ?
 *)
  
 ;;
esac

