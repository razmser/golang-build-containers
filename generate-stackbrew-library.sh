#!/usr/bin/env bash
set -Eeuo pipefail

declare -A aliases=(
	#[1.24]='1 latest'
)

# because we sort in versions.sh, we can assume the first non-rc in versions.json is the "latest" release
latest="$(jq -r 'first(keys_unsorted - ["tip"] | .[] | select(endswith("-rc") | not))' versions.json)"
[ -n "$latest" ]
aliases["$latest"]+=' 1 latest'
export latest

self="$(basename "$BASH_SOURCE")"
cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

if [ "$#" -eq 0 ]; then
	versions="$(jq -r 'keys_unsorted | map(@sh) | join(" ")' versions.json)"
	eval "set -- $versions"
fi

# no sort because we already sorted the keys in versions.sh (hence "keys_unsorted" above)

# get the most recent commit which modified any of "$@"
fileCommit() {
	git log -1 --format='format:%H' HEAD -- "$@"
}

# get the most recent commit which modified "$1/Dockerfile" or any file COPY'd from "$1/Dockerfile"
dirCommit() {
	local dir="$1"; shift
	(
		cd "$dir"
		files="$(
			git show HEAD:./Dockerfile | awk '
				toupper($1) == "COPY" {
					for (i = 2; i < NF; i++) {
						if ($i ~ /^--from=/) {
							next
						}
						print $i
					}
				}
			'
		)"
		fileCommit Dockerfile $files
	)
}

getArches() {
	local repo="$1"; shift
	local officialImagesBase="${BASHBREW_LIBRARY:-https://github.com/docker-library/official-images/raw/HEAD/library}/"

	local parentRepoToArchesStr
	parentRepoToArchesStr="$(
		find -name 'Dockerfile' -exec awk -v officialImagesBase="$officialImagesBase" '
				toupper($1) == "FROM" && $2 !~ /^('"$repo"'|scratch|.*\/.*)(:|$)/ {
					printf "%s%s\n", officialImagesBase, $2
				}
			' '{}' + \
			| sort -u \
			| xargs -r bashbrew cat --format '["{{ .RepoName }}:{{ .TagName }}"]="{{ join " " .TagEntry.Architectures }}"'
	)"
	eval "declare -g -A parentRepoToArches=( $parentRepoToArchesStr )"
}
getArches 'golang'

cat <<-EOH
# this file is generated via https://github.com/docker-library/golang/blob/$(fileCommit "$self")/$self

Maintainers: Tianon Gravi <admwiggin@gmail.com> (@tianon),
             Joseph Ferguson <yosifkit@gmail.com> (@yosifkit),
             Johan Euphrosine <proppy@google.com> (@proppy)
GitRepo: https://github.com/docker-library/golang.git
Builder: buildkit
EOH

# prints "$2$1$3$1...$N"
join() {
	local sep="$1"; shift
	local out; printf -v out "${sep//%/%%}%s" "$@"
	echo "${out#$sep}"
}

for version; do
	export version
	variants="$(jq -r '.[env.version].variants | map(@sh) | join(" ")' versions.json)"
	eval "variants=( $variants )"

	versionAliases=(
		$version
		${aliases[$version]:-}
	)

	defaultDebianVariant="$(jq -r '
		.[env.version].variants
		| map(select(
			startswith("alpine")
			or startswith("slim-")
			or startswith("windows/")
			| not
		))
		| .[0]
	' versions.json)"
	defaultAlpineVariant="$(jq -r '
		.[env.version].variants
		| map(select(
			startswith("alpine")
		))
		| .[0]
	' versions.json)"

	for v in "${variants[@]}"; do
		dir="$version/$v"
		[ -f "$dir/Dockerfile" ] || continue

		variant="$(basename "$v")"

		fullVersion="$(jq -r '.[env.version].version' versions.json)"

		if [ "$version" = "$fullVersion" ]; then
			baseAliases=( "${versionAliases[@]}" )
		else
			baseAliases=( $fullVersion "${versionAliases[@]}" )
		fi
		variantAliases=( "${baseAliases[@]/%/-$variant}" )
		variantAliases=( "${variantAliases[@]//latest-/}" )

		if [ "$variant" = "$defaultAlpineVariant" ]; then
			variantAliases+=( "${baseAliases[@]/%/-alpine}" )
			variantAliases=( "${variantAliases[@]//latest-/}" )
		fi

		case "$v" in
			windows/*)
				variantArches='windows-amd64'
				;;

			*)
				variantParent="$(awk 'toupper($1) == "FROM" { print $2 }' "$dir/Dockerfile" | sort -u)" # TODO this needs to handle multi-parents (we get lucky that they're the same)
				variantArches="${parentRepoToArches[$variantParent]}"
				;;
		esac

		# cross-reference with supported architectures
		for arch in $variantArches; do
			if ! jq -e --arg arch "$arch" '
				.[env.version].arches[$arch].supported
				# if the version we are checking is "tip", we need to cross-reference "latest" also (since it uses latest as GOROOT_BOOTSTRAP via COPY --from)
				and if env.version == "tip" then
					.[env.latest].arches[$arch].supported
				else true end
			' versions.json &> /dev/null; then
				variantArches="$(sed <<<" $variantArches " -e "s/ $arch / /g")"
			fi
		done
		# TODO rewrite this whole loop into a single jq expression :)
		variantArches="${variantArches% }"
		variantArches="${variantArches# }"
		if [ -z "$variantArches" ]; then
			echo >&2 "error: '$dir' has no supported architectures!"
			exit 1
		fi

		sharedTags=()
		for windowsShared in windowsservercore nanoserver; do
			if [[ "$variant" == "$windowsShared"* ]]; then
				sharedTags=( "${baseAliases[@]/%/-$windowsShared}" )
				sharedTags=( "${sharedTags[@]//latest-/}" )
				break
			fi
		done
		if [ "$variant" = "$defaultDebianVariant" ] || [[ "$variant" == 'windowsservercore'* ]]; then
			sharedTags+=( "${baseAliases[@]}" )
		fi

		constraints=
		if [ "$variant" != "$v" ]; then
			constraints="$variant"
			if [[ "$variant" == nanoserver-* ]]; then
				# nanoserver variants "COPY --from=...:...-windowsservercore-... ..."
				constraints+=", windowsservercore-${variant#nanoserver-}"
			fi
		fi

		commit="$(dirCommit "$dir")"

		echo
		echo "Tags: $(join ', ' "${variantAliases[@]}")"
		if [ "${#sharedTags[@]}" -gt 0 ]; then
			echo "SharedTags: $(join ', ' "${sharedTags[@]}")"
		fi
		cat <<-EOE
			Architectures: $(join ', ' $variantArches)
			GitCommit: $commit
			Directory: $dir
		EOE
		if [ -n "$constraints" ]; then
			echo 'Builder: classic'
			echo "Constraints: $constraints"
		fi
	done
done
