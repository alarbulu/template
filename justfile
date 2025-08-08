export VIRTUAL_ENV  := env("VIRTUAL_ENV", ".venv")

export BIN := VIRTUAL_ENV + if os_family() == "unix" { "/bin" } else { "/Scripts" }

export DEFAULT_PYTHON := if os_family() == "unix" { `cat .python-version` }  else { "python" }
# ensure valid virtualenv
virtualenv *args:
    #!/usr/bin/env bash
    set -euo pipefail

    # Create venv; installs `uv`-managed python if python interpreter not found
    test -d $VIRTUAL_ENV || uv venv --python $DEFAULT_PYTHON {{ args }}

    # Block accidentally usage of system pip by placing an executable at .venv/bin/pip
    echo 'echo "pip is not installed: use uv pip for a pip-like interface."' > .venv/bin/pip
    chmod +x .venv/bin/pip

_env:
    #!/usr/bin/env bash
    set -euo pipefail

    test -f .env || touch .env

_uv +args: virtualenv
    #!/usr/bin/env bash
    set -euo pipefail

    LOCKFILE_TIMESTAMP=$(grep -n "exclude-newer = " uv.lock | cut -d'=' -f2 | cut -d'"' -f2) || LOCKFILE_TIMESTAMP=""
    UV_EXCLUDE_NEWER=${UV_EXCLUDE_NEWER:-$LOCKFILE_TIMESTAMP}

    if [ -n "${UV_EXCLUDE_NEWER}" ]; then
        # echo "Using uv with UV_EXCLUDE_NEWER=${UV_EXCLUDE_NEWER}."
        export UV_EXCLUDE_NEWER
    else
        unset UV_EXCLUDE_NEWER
    fi

    opts=""
    if [ -n "${UV_EXCLUDE_NEWER}" ] && [ -n "$(grep "options.exclude-newer-package" uv.lock)" ]; then
        touch -d "$UV_EXCLUDE_NEWER" $VIRTUAL_ENV/.target
        while IFS= read -r line; do
            package="$(echo "${line%%=*}" | xargs)"
            date="$(echo "${line#*=}" | xargs)"
            touch -d "$date" $VIRTUAL_ENV/.package
            if [[ "{{ args }}" == *"--exclude-newer-package $package"* ]]; then
                continue # already set by the caller
            elif [ $VIRTUAL_ENV/.package -nt $VIRTUAL_ENV/.target ]; then
                opts="$opts --exclude-newer-package $package=$date"
            else
                echo "The cutoff for $package ($date) is older than the global cutoff and will no longer be specified."
            fi
        done < <(sed -n '/options.exclude-newer-package/,/^$/p' uv.lock | grep '=')
    fi

    uv {{ args }} $opts || exit 1

lock *args: (_uv "lock" args)

devenv: _env lock (_uv "sync --frozen") && install-precommit

install-precommit:
    #!/usr/bin/env bash
    set -euo pipefail

    BASE_DIR=$(git rev-parse --show-toplevel)
    test -f $BASE_DIR/.git/hooks/pre-commit || $BIN/pre-commit install

format *args=".": devenv
    $BIN/ruff format --check {{ args }}

lint *args=".": devenv
    $BIN/ruff check {{ args }}

# run the various dev checks but does not change any files
check: format lint

# fix formatting and import sort ordering
fix: devenv
    $BIN/ruff check --fix .
    $BIN/ruff format .

test *args: devenv
    PYTHONPATH={{ justfile_directory() }}/app {{ BIN }}/coverage run --source {{ justfile_directory() }} --module pytest {{ args }}
    {{ BIN }}/coverage report || {{ BIN }}/coverage html



update-dependencies date="": virtualenv
    #!/usr/bin/env bash
    set -euo pipefail

    LOCKFILE_TIMESTAMP=$(grep -n "exclude-newer = " uv.lock | cut -d'=' -f2 | cut -d'"' -f2) || LOCKFILE_TIMESTAMP=""
    if [ -z "{{ date }}" ]; then
        UV_EXCLUDE_NEWER=${UV_EXCLUDE_NEWER:-$LOCKFILE_TIMESTAMP}
    else
        UV_EXCLUDE_NEWER=${UV_EXCLUDE_NEWER:-$(date -d "{{ date }}" +"%Y-%m-%dT%H:%M:%SZ")}
    fi

    if [ -n "${UV_EXCLUDE_NEWER}" ]; then
        if [ -n "${LOCKFILE_TIMESTAMP}" ]; then
            touch -d "$UV_EXCLUDE_NEWER" $VIRTUAL_ENV/.target
            touch -d "$LOCKFILE_TIMESTAMP" $VIRTUAL_ENV/.existing
            if [ $VIRTUAL_ENV/.existing -nt $VIRTUAL_ENV/.target ]; then
                echo "The lockfile timestamp is newer than the target cutoff. Using the lockfile timestamp."
                UV_EXCLUDE_NEWER=$LOCKFILE_TIMESTAMP
            fi
        fi
        echo "UV_EXCLUDE_NEWER set to $UV_EXCLUDE_NEWER."
        export UV_EXCLUDE_NEWER
    else
        echo "UV_EXCLUDE_NEWER not set."
        unset UV_EXCLUDE_NEWER
    fi

    opts=""
    if [ -n "${UV_EXCLUDE_NEWER}" ] && [ -n "$(grep "options.exclude-newer-package" uv.lock)" ]; then
        touch -d "$UV_EXCLUDE_NEWER" $VIRTUAL_ENV/.target
        while IFS= read -r line; do
            package="$(echo "${line%%=*}" | xargs)"
            date="$(echo "${line#*=}" | xargs)"
            touch -d "$date" $VIRTUAL_ENV/.package
            if [ $VIRTUAL_ENV/.package -nt $VIRTUAL_ENV/.target ]; then
                opts="$opts --exclude-newer-package $package=$date"
            else
                echo "The cutoff for $package ($date) is older than the global cutoff and will no longer be specified."
            fi
        done < <(sed -n '/options.exclude-newer-package/,/^$/p' uv.lock | grep '=')
    fi

    uv lock --upgrade $opts || exit 1
