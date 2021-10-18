#!/usr/bin/env bash

version=""

#### Installation Functions ####

get_arch(){
  case "$(uname -m)" in 
    x86_64) echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *) echo "$arch is unsupported for CircleCI Runner on macOS"; exit 1 ;; 
  esac
}

#download_launch_agent(){
#  local attempt=0
#  local checksums=""
#
#  # there is an actual flag for this that I can't remember at the moment, look it up and put in incase of PR
#  if [ ! -z "$1" ]; then  
#    attempt=$1 
#  fi
#
#  echo "Attempting to download and verify CircleCI Launch Agent: attempt $attempt"
#
#  if [ $attempt -gt 2 ]; then
#    echo "Unable to download and validate CircleCI Launch Agent after 3 attempts, please try again later"; exit 1
#  fi
#
#
#  base_url="https://circleci-binary-releases.s3.amazonaws.com/circleci-launch-agent"
#
#  if [ -z "$v" ]; then
#    version=$(curl -s "${base_url}/release.txt")
#    if [ -z "$version" ]; then
#      echo "Unable to determine CircleCI Runner version to install"
#    fi
#  fi
#
#  checksums=$(curl -sSL "$base_url/$version/checksums.txt")
#  file="$(echo "$checksums" | grep -F "$platform" | cut -d ' ' -f 2 | sed 's/^.//')"
#  mkdir -p $(echo $file | sed 's/circleci-launch-agent//')
#
#  echo "Downloading CircleCI Launch Agent $version to $file"
#  curl --compressed -sL "$base_url/$version/$file" -o "$file" || download_launch_agent $((attempt + 1))
#  
#  # Verifying download
#  grep "$file" checksums.txt | sha256sum --check && chmod +x "$file"; sudo cp "$file" "$prefix/circleci-launch-agent" || download_launch_agent $((attempt + 1))
#}

install_dependencies(){
  echo "installing installing installing woooo"
}

get_field(){
  # $1 expected as resp body
  # $2 expected as field
  echo "$(echo $1 | sed 's/,/\n/g' | sed 's/[{|}]//g' | grep $2 | awk -F "\":" '{ print $2 }')"
}

download_launch_agent(){
  local attempt={$2:-"0"}
  local runnerHost=${LAUNCH_AGENT_API_URL:-"https://runner.circleci.com"}
  local version={$1:-""}
  local arch="$(get_arch)"

  body="{\"arch\":\"$arch\", \"os\":\"darwin\"}"

  dlResp=$(curl -f -X GET -s "$runnerHost/api/v2/launch-agent/download?version=$version&arch=arm64&os=darwin" \
    -d "$body" -H "content-type: application/json" -H "Authorization: Bearer $LAUNCH_AGENT_API_AUTH_TOKEN")
    
# error handling logic to implement for bad requests,
# exit code 22 is a bad or missing token and should not be retried
#  if [ "$?" -ne "0" ] then;
#    if [ $attempt -lt 3 ]; then
#      echo "nope"
#    fi
#  fi

  # should instead be grepping / awking it out? It'd be nice not to require peeps to have the jq  requirement
  checksum="$(get_field \"$dlResp\" \"checksum\")"
  dlURL="$(get_field \"$dlResp\" \"url\")"
  version="$(get_field \"$dlResp\" \"version\")"

  # make directory for launch-agent-download
  targetDir="darwin/$arch/$version"
  mkdir -p "$targetDir"
  echo "$dlURL"
  curl --compressed -L "$dlURL" -o "$targetDir/circleci-launch-agent"

}

#### Installation Script ####
# super user permissions are required to create new users, and directories in /opt
if [ ! $UID -eq 0 ]; then  
  echo "CircleCI Runner installation must be ran with super user permissions, please rerun with sudo"; 
  exit 1
fi

if [ -z "$LAUNCH_AGENT_API_AUTH_TOKEN" ]; then
  echo "Runner token not found in the \$LAUNCH_AGENT_API_AUTH_TOKEN environment variable, please set and start installation again"
  echo "see https://circleci.com/docs/2.0/runner-installation/ for details"
  exit 1
fi

base_url="https://circleci-binary-releases.s3.amazonaws.com/circleci-launch-agent"
prefix=/opt/circleci
platform="darwin/$(get_arch)"

while getopts 'p:v:' flag; do
  case "${flag}" in
    # Set prefix dir
    p) prefix="${OPTARG}" ;;
    v) version="${OPTARG}" ;;
  esac
done

# Set up runner directory
mkdir -p "$prefix/workdir"

# Downloading launch agent
echo "Downloading and verifying CircleCI Launch Agent Binary"

download_launch_agent


