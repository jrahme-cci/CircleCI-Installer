#!/usr/bin/env bash

version=""

binaryName="circleci-launch-agent"
configFileName="launch-agent-config.yaml"
defaultUser="circleci"

# Default binary & config installation location
prefix=/opt/circleci
configDir=/Library/Preferences/com.circleci.runner
launchConfigDir=/Library/LaunchDaemons

defaultConfig="api:
  auth_token: $LAUNCH_AGENT_API_AUTH_TOKEN

  runner:
    command_prefix: [\"sudo\", \"-niHu\", \"$defaultUser\", \"--\"]
    working_directory: /tmp/%s
    cleanup_working_directory: true

  logging:
    file: /Library/Logs/com.circleci.runner.log"

defaultLaunchConfig="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple Computer//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
    <dict>
        <key>Label</key>
        <string>com.circleci.runner</string>

        <key>Program</key>
        <string>$prefix/$binaryName</string>

        <key>ProgramArguments</key>
        <array>
            <string>$binaryName</string>
            <string>--config</string>
            <string>/Library/Preferences/com.circleci.runner/$configFileName</string>
        </array>

        <key>RunAtLoad</key>
        <true/>

        <!-- The agent needs to run at all times -->
        <key>KeepAlive</key>
        <true/>

        <!-- This prevents macOS from limiting the resource usage of the agent -->
        <key>ProcessType</key>
        <string>Interactive</string>

        <!-- Increase the frequency of restarting the agent on failure, or post-update -->
        <key>ThrottleInterval</key>
        <integer>3</integer>

        <!-- Wait for 10 minutes for the agent to shut down (the agent itself waits for tasks to complete) -->
        <key>ExitTimeOut</key>
        <integer>600</integer>

        <!-- The agent uses its own logging and rotation to file -->
        <key>StandardOutPath</key>
        <string>/dev/null</string>
        <key>StandardErrorPath</key>
        <string>/dev/null</string>
    </dict>
</plist>
"

#### Installation Functions ####

get_arch(){
  case "$(uname -m)" in 
    x86_64) echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *) echo "$arch is unsupported for CircleCI Runner on macOS"; exit 1 ;; 
  esac
}

installDeps=("curl" "shasum")
runtimeDeps=("tar" "git" "gzip")

validate_dependencies(){
  if ! command -v grep &> /dev/null; then
    echo yeah
  fi
}

get_field(){
  # $1 expected as resp body
  # $2 expected as field
  echo "$1" | sed 's/,/\n/g' | sed 's/[{|}]//g' | grep "$2" | awk -F "\":" '{ print $2 }' | tr -d '"'
}

download_launch_agent(){
  local attempt=${2:-"0"}
  local runnerHost=${LAUNCH_AGENT_API_URL:-"https://runner.circleci.com"}
  local version=${1:-""}
  local arch="$(get_arch)"

  if [ "$attempt" -ge 3 ]; then
    echo "Unable to download launch agent after $attempt attempts. Please try again later"
    exit 1
  fi

  if [ -z "$version" ]; then
    body="{\"arch\":\"$arch\", \"os\":\"darwin\"}"
  else
    body="{\"arch\":\"$arch\", \"os\":\"darwin\", \"version\":\"$version\"}"
  fi

  dlResp=$(curl -f -X GET -s "$runnerHost/api/v2/launch-agent/download" \
    -d "$body" -H "content-type: application/json" -H "Authorization: Bearer $LAUNCH_AGENT_API_AUTH_TOKEN")
    
  # exit code 22 is a bad or missing token and should not be retried
  exitCode="$?"
  if [ "$exitCode" -ne 0 ]; then
    if [ "$exitCode" -eq 22 ]; then
      echo "Invalid or missing token. Please set LAUNCH_AGENT_API_AUTH_TOKEN to a valid runner token"
      exit 1
    fi
    download_launch_agent "" $((attempt + 1))
  fi

  local checksum="$(get_field "$dlResp" "checksum")"
  local dlURL="$(get_field "$dlResp" "url")"
  local version="$(get_field "$dlResp" "version")"

  # make directory for launch-agent-download
  targetDir="darwin/$arch/$version"
  mkdir -p "$targetDir"

  # download the launch agent binary
  curl -s --compressed -L "$dlURL" -o "$targetDir/$binaryName"

  # validate the checksum
  local actualChecksum="$(shasum -a 256 "$targetDir/$binaryName" | awk '{print $1}')"
  if [ "$actualChecksum" == "$checksum" ]; then
    echo "$targetDir/$binaryName"
  else
    download_launch_agent "" $((attempt + 1))
  fi
}

configure_launch_agent(){
  # Create the configuration directories
  mkdir -p "$configDir"
  mkdir -p "$launchConfigDir"

  echo "$defaultConfig" > "$configDir"/"$configFileName"

  echo "$defaultLaunchConfig" > "$launchConfigDir"/com.circleci.runner.plist
  chmod 644 "$launchConfigDir"/com.circleci.runner.plist
}

#### Installation Script ####
# super user permissions are required to create new users, and directories in /opt
while getopts 'p:v:n:' flag; do
  case "${flag}" in
    # Set prefix dir
    p) prefix="${OPTARG}" ;;
    v) version="${OPTARG}" ;;
    *) exit 1;;
  esac
done

if [ ! $UID -eq 0 ]; then  
  echo "CircleCI Runner installation must be ran with super user permissions, please rerun with sudo"; 
  exit 1
fi

if [ -z "$LAUNCH_AGENT_API_AUTH_TOKEN" ]; then
  echo "Runner token not found in the \$LAUNCH_AGENT_API_AUTH_TOKEN environment variable, please set and start installation again"
  echo "See https://circleci.com/docs/2.0/runner-installation/ for details"
  exit 1
fi

validate_dependencies

# Set up runner directory
mkdir -p "$prefix/workdir"

# Downloading launch agent
echo "Downloading and verifying CircleCI Launch Agent Binary"
binaryPath="$(download_launch_agent)"

# Move the launch agent to the correct directory
cp "$binaryPath" "$prefix/$binaryName"
chmod +x "$prefix/$binaryName"  # Should this set executable for all users or just owner?

echo "Installing the CircleCI Launch Agent"

# Create the configuration
configure_launch_agent

# The agent may already be loaded, if it's not ignore the error
launchctl unload "$launchConfigDir/com.circleci.runner.plist" 2> /dev/null
launchctl load "$launchConfigDir/com.circleci.runner.plist"

# Is this a good idea? Could cause an issue if the temp install dir already exists and has stuff in it
echo "$binaryPath" | rm -rf "$(awk -F '/' '{print $1}')"

echo "CircleCI Launch Agent Binary succesfully installed"
echo "To validate the CircleCI Launch Agent is running correctly, you can check in log reports for the logs called com.circleci.runner.log"