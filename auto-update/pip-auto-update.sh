#!/bin/bash

. ./common.sh
. ../.env

python_service_name_list=("portfolio-app" "finote-app" "shifree-app")
script_path=$(cd $(dirname $0); pwd)

update_requirements() {
    local index=$1
    local file_path="${REQUIREMENTS_FOLDER_PATH_LIST[index]}requirements.txt"

    docker exec -i ${python_service_name_list[index]} pip freeze > $file_path
}

update() {
    local index=$1
    local is_skip=$2
    local outdated_pkg
    local error_pkg_info_list=()
    local docker_exec_command="docker exec -i ${python_service_name_list[index]}"

    # docker execが失敗するサービスは以降の処理を実施しない
    if [ $is_skip -eq 1 ]; then
        write_csv "error_pkg" $index ""
        write_csv "is_rollback" $index 0
        write_csv "skip" $index "\n:x: *${python_service_name_list[index]}* is Skip\n"
        exit
    fi

    write_csv "skip" $index ""

    ${docker_exec_command} pip install -U pip --user 2>/dev/null
    
    local outdated_pkg_list=$(${docker_exec_command} pip list --outdated --format=freeze | awk -F "==" '{print $1}')
    local outdated_pkg_list=(`echo $outdated_pkg_list`)

    for outdated_pkg in ${outdated_pkg_list[@]}; do
        local now_version=$(${docker_exec_command} pip list | grep $outdated_pkg | awk -F " " '{print $2}')
        local update_error=$(${docker_exec_command} pip install -U $outdated_pkg --user 2>&1 > /dev/null | grep ERROR)

        # pip installでエラーが起きた場合はバージョンを戻す
        if [ -n "$update_error" ]; then
            ${docker_exec_command} pip install "${outdated_pkg}==${now_version}" --user

            local tmp_pkg_info="${outdated_pkg}==${now_version}"
            error_pkg_info_list+=($tmp_pkg_info)
        fi
    done

    ${docker_exec_command} pip check
    status=$?

    # 依存関係が解消されない場合はrequirements.txtを更新せずに再起動で元に戻す
    if [ $status = 1 ]; then
        write_csv "is_rollback" $index 1
    else
        write_csv "is_rollback" $index 0

        local error_pkg_info_text=$(create_error_pkg_text ${error_pkg_info_list[@]})
        write_csv "error_pkg" $index $error_pkg_info_text

        update_requirements $index
        git_push_submodule $index ${REQUIREMENTS_FOLDER_PATH_LIST[index]} ${PIP_REPOSITORY_NAME_LIST[index]}
    fi
}

create_error_pkg_text() {
    local error_pkg_info_list=("$@")
    local error_pkg_info_text=""

    if [ ${#error_pkg_info_list[@]} -ge 1 ]; then
        error_pkg_info_text="${error_pkg_info_text}\`\`\`【ErrorDependency】\n"

        for error_pkg_info in ${error_pkg_info_list[@]}; do
            error_pkg_info_text="${error_pkg_info_text}・${error_pkg_info}\n"
        done

        error_pkg_info_text="${error_pkg_info_text}\`\`\`"
    fi

    echo $error_pkg_info_text
}

main() {
    # dockerの生存確認
    local result_check_container=$(check_container "pip freeze" ${python_service_name_list[@]})
    result_check_container=(`echo $result_check_container`)

    local command=""
    local index

    init_tmp_files

    for index in "${!python_service_name_list[@]}"; do
        command="${command}update ${index} ${result_check_container[index]} & "
    done

    eval $command
    wait

    # aggregate関連
    local git_push_aggregate_result=$(git_push_aggregate ${PIP_REPOSITORY_NAME_LIST[@]})
    local git_push_aggregate_result_text=$(create_aggregate_result_text $git_push_aggregate_result)

    # docker restart関連
    local restart_docker_statues=$(restart_docker)
    local docker_restart_status_text=$(create_docker_restart_status_text ${python_service_name_list[index]} ${restart_docker_statues[@]})

    local updated_text=$(collect_text_from_csv ${python_service_name_list[@]})

    send_notification "$updated_text$git_push_aggregate_result_text$docker_restart_status_text" "pip-auto-update" "https://img.icons8.com/color/480/000000/python.png"

    remove_tmp_files
}

main
