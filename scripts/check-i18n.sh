#!/bin/bash
#
# Inspired by https://github.com/kubernetes/website/blob/main/scripts/lsync.sh

COMMIT_HASH_ARG=""
DEFAULT_CONTENT="content"
DEFAULT_LANG="en"
DEFAULT_TARGET="$DEFAULT_CONTENT"
EXIT_STATUS=0
EXTRA_DIFF_ARGS="--numstat"
FLAG_CHANGE_OR_ADD=0
FLAG_DIFF_DETAILS=0
FLAG_DRIFTED_STATUS=0
FLAG_FAIL_ON_LIST_OR_MISSING=0
FLAG_INFO=""
FLAG_QUIET=""
FLAG_VERBOSE=""
I18N_DLC_KEY="default_lang_commit"
I18N_DLD_KEY="drifted_from_default" # true, false, file not found
LIST_KIND="DRIFTED" # or "ALL" or "NEW"
TARGET_PATHS=""


function _usage() {
  cat <<EOS
Usage: $(basename "$0") [options] [TARGET_PATH ...]

  List, and optionally update, target localization pages (TLP).

  By default the processed and listed TLP include only localization pages that
  have drifted, that is, pages that are out-of-sync with their English
  counterparts. Flags are available to list all TLP in range of the target
  paths, and to list only those that are missing the front-matter
  $I18N_DLC_KEY key.

  TARGET_PATH can be a single markdown file, such as 'content/ja/_index.md', or
  a directory of localized pages, such as 'content/ja'. The default TARGET_PATH
  is '$DEFAULT_TARGET'.

Options:

  -a       List/process all localization page files accessible through target paths.

  -c HASH  Change or add the '$I18N_DLC_KEY' key value to HASH for all selected
           localization pages. Use 'HEAD' as a shorthand for the hash of 'main'
           at HEAD (read locally). Also sets '$I18N_DLD_KEY' to true for files
           that have drifted.

           TIP: first fetch and pull the upstream 'main' if you want to use the
                remote HEAD hash.

  -d       Output diff details.
  -D       Update or add the '$I18N_DLD_KEY' key to all target localization pages.
  -h       Help! Output this usage info.

  -i       Print commit hashes of the local 'main' branch that might be useful to
           use as an argument to -c.

  -n       List/process only new localization pages, those without a '$I18N_DLC_KEY' key.
  -q       Quiet mode. Do not list processed files. Prints summary unless -x is set.
  -v       Verbose mode. List all processed files and their status.
  -x       Return non-zero exit code if files were listed or hashes are missing.
EOS
}

function usage() {
  local status=${1:-0}
  _usage 1>&2
  exit $status
}

function process_CLI_args() {
  while getopts ":ac:dDhinqvx" opt; do
    case $opt in
      a)
        LIST_KIND="ALL";;
      c)
        FLAG_CHANGE_OR_ADD=1;
        COMMIT_HASH_ARG="$OPTARG";;
      d)
        FLAG_DIFF_DETAILS=1
        EXTRA_DIFF_ARGS="";;
      D)
        FLAG_DRIFTED_STATUS=1;;
      h)
        usage;;
      i)
        FLAG_INFO=1;;
      n)
        LIST_KIND="NEW";;
      q)
        FLAG_QUIET=1;;
      v)
        FLAG_VERBOSE=1;;
      x)
        FLAG_FAIL_ON_LIST_OR_MISSING=1;;
      \?)
        echo -e "ERROR: invalid option: -$OPTARG\n" >&2
        usage 1;;
      :)
        echo -e "ERROR: option -$OPTARG requires an argument.\n" >&2
        usage 1;;
    esac
  done

  if [[ -n $COMMIT_HASH_ARG ]]; then
    COMMIT_HASH_ARG=$(echo $COMMIT_HASH_ARG | tr '[:upper:]' '[:lower:]')
    validate_hash $COMMIT_HASH_ARG
  fi

  if (( FLAG_CHANGE_OR_ADD + FLAG_DIFF_DETAILS + FLAG_DRIFTED_STATUS > 1 )); then
    echo -e "ERROR: you can't use -c, -d, and -D at the same time; choose one. For help use -h.\n"
    exit 1
  fi

  if [[ -n $FLAG_QUIET && $FLAG_DIFF_DETAILS != 0 ]]; then
    echo -e "ERROR: use -d or -q not both. For help use -h.\n"
    exit 1
  fi

  if [[ -n $FLAG_QUIET && ($LIST_KIND == "ALL" || -n $FLAG_VERBOSE) ]]; then
    echo -e "ERROR: -q flag ignored when -a or -v is used. For help use -h.\n"
    exit 1
  fi

  if [[ $LIST_KIND == "ALL" && -n $COMMIT_HASH_ARG ]]; then
    read -p "CAUTION! Set hash for all targets? (y/n): " response
    if [[ ! $response =~ ^[Yy] ]]; then
      echo "Aborting"
      exit 1
    fi
  fi

  shift $((OPTIND-1))
  TARGET_PATHS="$@"

  if [[ -z "$TARGET_PATHS" ]]; then
    TARGET_PATHS="$DEFAULT_TARGET"
    # [[ -n $FLAG_VERBOSE ]] || echo "INFO: using default target path: $TARGET_PATHS"
  fi

  if [[ -n $FLAG_VERBOSE ]]; then
    echo "INFO: local branches"
    git branch -vv
    echo
  fi

  if [[ -z $FLAG_QUIET ]]; then
    echo "Processing paths: $TARGET_PATHS"
  fi

  if [[ -f "TARGET_PATHS" && ! -e "$TARGET_PATHS" ]] ; then
    echo -e "ERROR: path not found: '$TARGET_PATHS'\n" >&2
    exit 2
  fi
}

validate_hash() {
  local hash=$1

  if [[ $hash =~ ^\s*$ ]]; then
    echo -e "ERROR: empty hash argument.\n" >&2
    exit 1
  fi

  if [[ $hash == "head" ]]; then return; fi

  if ! [[ $hash =~ ^[0-9a-fA-F]{7,40}(\+[0-9]+)?$ ]]; then
    echo -e "ERROR: invalid hash '$hash'\n" >&2
    usage 1
  fi
}

BRANCH_MAIN_HASH="" # commit at which this branch joins `main`
MAIN_HEAD_HASH=""   # commit of `main` at HEAD

function get_and_print_hashes_of_main() {
  BRANCH_MAIN_HASH=$(git merge-base main HEAD)
  MAIN_HEAD_HASH=$(git rev-parse main)

  if [[ -z $FLAG_INFO ]]; then return; fi
  echo "$BRANCH_MAIN_HASH - hash at which current branch joins 'main'"
  echo "$MAIN_HEAD_HASH - hash of 'main' at HEAD"
}

function set_file_i18n_hash() {
  # Arguments: <file> <commit-hash> [<msg>]
  #
  # Sets the front matter field $I18N_DLC_KEY to <commit-hash>,
  # or adds the key if missing.

  local f="$1"
  local HASH="$2"
  local pre_msg="${3:--\t-}"
  local post_msg="${4:-key}"

  if grep -q "^$I18N_DLC_KEY:" "$f"; then
    perl -i -pe "s/(^$I18N_DLC_KEY):.*$/\$1: $HASH/" "$f"
    post_msg="$post_msg UPDATED"
  else
    perl -i -0777 -pe "s/^(---.*?)(\n---\n)/\$1\n$I18N_DLC_KEY: $HASH\$2/sm" "$f"
    post_msg="$post_msg ADDED"
  fi
  if [[ -z $FLAG_QUIET ]]; then
    echo -e "$pre_msg\t$f $HASH $post_msg"
  fi
}

function update_file_i18n_hash() {
  local f="$1"
  local HASH="$2"
  local pre_msg="$3"
  local post_msg="${4:- UPDATED key}"

  if [[ -z $HASH ]]; then
    echo "INTERNAL ERROR: update_file_i18n_hash: hash should not be empty - $f $msg"
    exit 1
  fi

  # if ! git branch --contains $HASH | grep -q "^\s*main\b"; then
  #   HASH=$MAIN_HEAD_HASH
  #   echo "WARNING: the given hash is not on 'main', using this instead: $HASH" >&2
  # fi

  if ! (git branch --contains $HASH | grep -qEe "^\S?\s*main$"); then
    echo "ERROR: hash isn't on the default branch (main), aborting: $HASH - $f" >&2
    exit 1
  fi

  set_file_i18n_hash "$f" "$HASH" "$msg" $pre_msg $post_msg
}

function set_file_drifted_status() {
  if [[ $FLAG_DRIFTED_STATUS == 0 ]]; then return; fi

  local f="$1"
  local status="$2"
  local pre_msg="${3:- \t }"
  local post_msg="${4:-$I18N_DLD_KEY key}" # Not used atm

  if [[ $status == "false" ]]; then
    perl -i -pe "s/(^$I18N_DLD_KEY):.*\n$//g" "$f"
  elif grep -q "^$I18N_DLD_KEY:" "$f"; then
    perl -i -pe "s/(^$I18N_DLD_KEY):.*$/\$1: $status/" "$f"
    post_msg="$post_msg UPDATED"
  elif ! grep -q "^$I18N_DLC_KEY:" "$f"; then
    echo "ERROR: $I18N_DLC_KEY key is missing. Cannot set $I18N_DLC_KEY in $f" >&2
    exit 1
  else
    # Add drifted status immediately after the i18n hash
    perl -i -0777 -pe "s/($I18N_DLC_KEY:.*?\n)/\$1$I18N_DLD_KEY: $status\n/sm" "$f"
    # perl -i -0777 -pe "s/^(---.*?)(\n---\n)/\$1\n$I18N_DLD_KEY: $status\$2/sm" "$f"
    post_msg="$post_msg ADDED"
  fi
  if [[ -n $FLAG_VERBOSE ]]; then
    echo -e "$pre_msg\t$f $I18N_DLD_KEY key set to $status"
  fi
}

function main() {
  process_CLI_args "$@"

  if [[ -n $FLAG_INFO ]]; then
    get_and_print_hashes_of_main
    return
  fi

  if [ -f "$TARGET_PATHS" ] ; then
    TARGETS="$TARGET_PATHS"
  else
    # TODO: better handle errors reported by find?
    TARGETS=$(find $TARGET_PATHS -name "*.md" -not -path "*/$DEFAULT_LANG/*")
    if [[ -z "$TARGETS" ]]; then
      echo "ERROR: target directory contains no markdown files: '$TARGET_PATHS'" >&2
      exit 1
    fi
    # if [[ -n $FLAG_VERBOSE ]]; then echo -e "All targets: $TARGETS"; fi
  fi

  local LASTCOMMIT_FF=""       # commit From File (FF), i.e., $f in the loop below
  local LASTCOMMIT_GIT=""      # last commit of `en` version of $f from git
  local FILE_COUNT=0           # Number of TLP
  local FILE_PROCESSED_COUNT=0 # Number of TLP actually listed

  if [[ $COMMIT_HASH_ARG == "head" ]]; then
    if [[ -z $MAIN_HEAD_HASH ]]; then get_and_print_hashes_of_main; fi
    COMMIT_HASH_ARG=$MAIN_HEAD_HASH
  fi

  for f in $TARGETS; do
    ((FILE_COUNT++))

    LASTCOMMIT_FF=$(perl -ne "print \"\$1\" if /^$I18N_DLC_KEY:\\s*([a-f0-9]+)/i" "$f")
    LASTCOMMIT="$LASTCOMMIT_FF"

    if [[ $LIST_KIND == "ALL" && -n $COMMIT_HASH_ARG ]]; then
        ((FILE_PROCESSED_COUNT++))
        set_file_i18n_hash "$f" "$COMMIT_HASH_ARG"
        continue
    fi

    if [[ $LIST_KIND == "NEW" ]]; then
      if [[ -n $LASTCOMMIT_FF ]]; then continue; fi
      ((FILE_PROCESSED_COUNT++))
      if [[ -n $COMMIT_HASH_ARG ]]; then
        set_file_i18n_hash "$f" "$COMMIT_HASH_ARG" "" "key ADDED"
      elif [[ -z $FLAG_QUIET ]]; then
        echo "$f - has no $I18N_DLC_KEY front-matter key"
      fi
      continue
    fi

    ## Processing $LIST_KIND DRIFTED

    # Does $f have an default-language version?
    EN_VERSION=$(echo "$f" | sed "s/$DEFAULT_CONTENT\/.\{2,5\}\//$DEFAULT_CONTENT\/$DEFAULT_LANG\//g")
    if [[ ! -e "$EN_VERSION" ]]; then
      ((FILE_PROCESSED_COUNT++))
      if [[ -z $FLAG_QUIET ]]; then
        echo -e "File not found:\t$f - $DEFAULT_LANG page was removed or renamed"
      fi
      set_file_drifted_status "$f" "file not found"
      continue
    fi

    # Check default-language version for changes
    DIFF=$(git diff --exit-code $EXTRA_DIFF_ARGS $LASTCOMMIT...HEAD "$EN_VERSION" 2>&1)
    DIFF_STATUS=$?
    DRIFTED_STATUS="false"
    if [ $DIFF_STATUS -gt 1 ]; then
      ((FILE_PROCESSED_COUNT++))
      EXIT_STATUS=$DIFF_STATUS
      echo -e "HASH\tERROR\t$f: git diff error ($DIFF_STATUS) or invalid hash $LASTCOMMIT. For details, use -v."
      if [[ -n $FLAG_VERBOSE ]]; then echo "$DIFF"; fi
      continue
    elif [[ -n "$DIFF" ]]; then
      ((FILE_PROCESSED_COUNT++))
      DRIFTED_STATUS="true"
      if [[ $FLAG_DIFF_DETAILS != 0 ]]; then
        echo "$DIFF"
      elif [[ -n $COMMIT_HASH_ARG ]]; then
        update_file_i18n_hash "$f" "$COMMIT_HASH_ARG" "$DIFF"
      elif [[ -z $FLAG_QUIET ]]; then
        echo -n "> Drifted file: $f"
        if [[ -n $FLAG_VERBOSE ]]; then echo "; diff summary: $DIFF"; else echo; fi
      fi
    elif [[ -z $LASTCOMMIT ]]; then
      ((FILE_PROCESSED_COUNT++))
      local msg="New i18n file"
      if [[ -n $COMMIT_HASH_ARG ]]; then
        set_file_i18n_hash "$f" "$COMMIT_HASH_ARG" "$msg" "key ADDED"
      elif [[ -z $FLAG_QUIET ]]; then
        echo "$msg - $f"
      fi
    elif [[ $LIST_KIND == "ALL" || -n $FLAG_VERBOSE ]]; then
      ((FILE_PROCESSED_COUNT++))
      echo -e "File is in sync\t$f - $LASTCOMMIT"
    fi
    set_file_drifted_status "$f" $DRIFTED_STATUS
  done

  if [[ -z $FLAG_QUIET || $FLAG_FAIL_ON_LIST_OR_MISSING == 0 ]]; then
    echo "$LIST_KIND files: $FILE_PROCESSED_COUNT out of $FILE_COUNT"
  fi

  if [[ $FILE_PROCESSED_COUNT -gt 0 && -z $COMMIT_HASH_ARG ]]; then
    EXIT_STATUS=$((EXIT_STATUS || FLAG_FAIL_ON_LIST_OR_MISSING))
  fi
  exit $EXIT_STATUS
}

main "$@"
