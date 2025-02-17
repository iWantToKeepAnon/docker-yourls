#!/bin/bash
set -eu

self="$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# get the most recent commit which modified any of "$@"
fileCommit() {
	git log -1 --format='format:%H' HEAD -- "$@"
}

# get the most recent commit which modified "$1/Dockerfile" or any file COPY'd from "$1/Dockerfile"
dirCommit() {
	local dir="$1"; shift
	(
		cd "$dir"
		fileCommit \
			Dockerfile \
			"$(git show HEAD:./Dockerfile | awk '
				toupper($1) == "COPY" {
					for (i = 2; i < NF; i++) {
						print $i
					}
				}
			')"
	)
}

getArches() {
	local repo="$1"; shift
	local officialImagesUrl='https://github.com/docker-library/official-images/raw/master/library/'

	eval "declare -g -A parentRepoToArches=( $(
		find . -name 'Dockerfile' -exec awk '
				toupper($1) == "FROM" && $2 !~ /^('"$repo"'|scratch|microsoft\/[^:]+)(:|$)/ {
					print "'"$officialImagesUrl"'" $2
				}
			' '{}' + \
			| sort -u \
			| xargs bashbrew cat --format '[{{ .RepoName }}:{{ .TagName }}]="{{ join " " .TagEntry.Architectures }}"'
	) )"
}
getArches 'yourls'

cat <<-EOH
# this file is generated via https://github.com/YOURLS/docker-yourls/blob/$(fileCommit "$self")/$self

Maintainers: YOURLS <yourls@yourls.org> (@YOURLS),
             Léo Colombaro <git@colombaro.fr> (@LeoColomb)
GitRepo: https://github.com/YOURLS/docker-yourls.git
EOH

# prints "$2$1$3$1...$N"
join() {
	local sep="$1"; shift
	local out; printf -v out "${sep//%/%%}%s" "$@"
	echo "${out#$sep}"
}

for variant in apache fpm fpm-alpine; do
	commit="$(dirCommit "$variant")"

	fullVersion="$(git show "${commit}:${variant}/Dockerfile" | awk '$1 == "ENV" && $2 == "YOURLS_VERSION" { print $3; exit }')"

	versionAliases=()
	while [ "${fullVersion%[.-]*}" != "$fullVersion" ]; do
		versionAliases+=( "$fullVersion" )
		fullVersion="${fullVersion%[.-]*}"
	done
	versionAliases+=(
		"$fullVersion"
		latest
	)

	variantAliases=( "${versionAliases[@]/%/-$variant}" )
	variantAliases=( "${variantAliases[@]//latest-/}" )

	if [ "$variant" = 'apache' ]; then
		variantAliases+=( "${versionAliases[@]}" )
	fi

	variantParent="$(awk 'toupper($1) == "FROM" { print $2 }' "$variant/Dockerfile")"
	# shellcheck disable=SC2154
	variantArches="${parentRepoToArches[$variantParent]}"

	echo
	cat <<-EOE
		Tags: $(join ', ' "${variantAliases[@]}")
		Architectures: $(join ', ' $variantArches)
		GitCommit: $commit
		Directory: $variant
	EOE
done
