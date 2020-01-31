#!/bin/bash

. ./common.sh
. ../.env

composer_service_name_list=("sumolog-app")

update() {
    local index=$1
    local is_skip=$2
    local docker_exec_command="docker exec -i ${composer_service_name_list[index]}"

    # docker execが失敗するサービスは以降の処理を実施しない
    if [ $is_skip -eq 1 ]; then
        write_csv "is_rollback" $index 0
        write_csv "skip" $index "\n:x: *${composer_service_name_list[index]}* is Skip\n"
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
            write_csv "skip" $index "\n:x: *${composer_service_name_list[index]}* is skip. Composer update error.\n"
            write_csv "git_push_submodule" $index ""
        fi
    else
        write_csv "is_rollback" $index 0
        write_csv "skip" $index "\n:x: *${composer_service_name_list[index]}* is skip. Composer update error.\n"
        write_csv "git_push_submodule" $index ""
    fi
}

main() {
    # dockerの生存確認
    local result_check_container=$(check_container "composer show -i" ${composer_service_name_list[@]})
    result_check_container=(`echo $result_check_container`)

    local command=""
    local index

    init_tmp_files

    for index in "${!composer_service_name_list[@]}"; do
        command="${command}update ${index} ${result_check_container[index]} & "
    done

    eval $command
    wait

    # aggregate関連
    local git_push_aggregate_result=$(git_push_aggregate ${COMPOSER_REPOSITORY_NAME_LIST[@]})
    local git_push_aggregate_result_text=$(create_aggregate_result_text $git_push_aggregate_result)

    # docker restart関連
    local restart_docker_statues=$(restart_docker ${COMPOSER_DOCKER_COMPOSE_FILE_PATH_LIST[@]})
    local docker_restart_status_text=$(create_docker_restart_status_text ${#composer_service_name_list[@]} ${composer_service_name_list[@]} ${restart_docker_statues[@]})

    local updated_text=$(collect_text_from_csv)

    send_notification "$updated_text$git_push_aggregate_result_text$docker_restart_status_text"

    remove_tmp_files
}

main
