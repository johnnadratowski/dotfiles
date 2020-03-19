function insert () {
  local name="${1}"
  local at="${2}"
  local dest="${3:-.}"

  local sep="${SEP:-_}"
  local pad="${PAD:-3}"

  if [[ "${name}" == "" ]]; then
    echo "Must specify name as first parameter"
    exit 1
  fi

  if [[ "${at}" == "" ]]; then
    echo "Must specify index as second parameter"
    exit 1
  fi

  for file in ${dest}/*; do
    if [[ "${file}" =~ ([[:digit:]]{3})${sep}(.+\.{0,1}.*) ]]; then
      local num="${BASH_REMATCH[1]}"
      local filename="${BASH_REMATCH[2]}"
      if (( num >= at )); then
        mv "${file}" "${dest}/$(printf "%0${pad}d\n" "$(( num + 1))")${sep}${filename}"
      fi
    fi
  done

  touch "${dest}/$(printf "%0${pad}d\n" "${at}")${sep}${name}"
}

insert $@