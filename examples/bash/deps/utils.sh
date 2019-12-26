function quote_csv () {
	echo -e "$1" | sed 's/"/""/g'
}

function trim_whitespace () {
	echo -e "$(python -c "import sys; sys.stdout.write('''$1'''.strip())")"
}

function trim_quotes () {
	echo -e "$(python -c "import sys; sys.stdout.write('''$1'''.strip('\"'))")"
}

function remove_non_alpha () {
	echo -e "$1" | tr -cd '[:alnum:]._-'
}

function normalize_whitespace () {
	echo -e "$1" | sed 's/\\n/ /g' | tr -d '\n'
}

function to_lower () {
	echo -e "${1,,}"
}

function clean_license_text () {
	local output="$(quote_csv "$(trim_quotes "$(trim_whitespace "$(normalize_whitespace "$1")")")")"
	echo -e "${output:0:32650}"
}
