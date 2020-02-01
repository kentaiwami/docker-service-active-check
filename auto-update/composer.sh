#!/bin/bash

. ./common.sh
. ../.env

service_names=("sumolog-app")

update() {
    local index=$1
    local is_skip=$2
    local docker_exec_command="docker exec -i ${service_names[index]}"

    # docker execが失敗するサービスは以降の処理を実施しない
    if [ $is_skip -eq 1 ]; then
        write_csv "is_rollback" $index 0
        write_csv "skip" $index "\n:x: *${service_names[index]}* is Skip\n"
        exit
    fi

    write_csv "skip" $index ""

    sudo /usr/local/bin/composer self-update --stable

    cd ${COMPOSER_JSON_FOLDER_PATH_LIST} && /usr/local/bin/composer update --dry-run

    local dry_run_command_status=$?

    if [ $dry_run_command_status -eq 0 ]; then
        /usr/local/bin/composer clear-cache
        /usr/local/bin/composer update
        local update_command_status=$?

        if [ $update_command_status -eq 0 ];then
            git_push_submodule $index ${COMPOSER_JSON_FOLDER_PATH_LIST[index]} ${COMPOSER_REPOSITORY_NAME_LIST[index]}
            write_csv "is_rollback" $index 0
        else
            write_csv "is_rollback" $index 0
            write_csv "skip" $index "\n:x: *${service_names[index]}* is skip. Composer update error.\n"
            write_csv "git_push_submodule" $index ""
        fi
    else
        write_csv "is_rollback" $index 0
        write_csv "skip" $index "\n:x: *${service_names[index]}* is skip. Composer update error.\n"
        write_csv "git_push_submodule" $index ""
    fi
}

main ${#service_names[@]} "composer show -i" "composer-auto-update" "https://getcomposer.org/img/logo-composer-transparent.png" ${service_names[@]} ${COMPOSER_REPOSITORY_NAME_LIST[@]} ${COMPOSER_DOCKER_COMPOSE_FILE_PATH_LIST[@]}
