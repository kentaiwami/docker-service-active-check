python_service_name_list=("portfolio-app" "finote-app" "shifree-app")

for python_service_name in ${python_service_name_list[@]}; do
    # 現在のインストール状態をpip check後のエラーに備えて一時保存する
    now_pkg_list=$(docker exec $python_service_name pip list --format=freeze)
    now_pkg_list=(`echo $now_pkg_list`)

    docker exec $python_service_name pip install -U pip

    outdated_pkg_list=$(docker exec $python_service_name pip list --outdated --format=freeze | awk -F "==" '{print $1}')
    outdated_pkg_list=(`echo $outdated_pkg_list`)

    for outdated_pkg in ${outdated_pkg_list[@]}; do
        now_version=$(docker exec $python_service_name pip list | grep $outdated_pkg | awk -F " " '{print $2}')
        update_error=$(docker exec $python_service_name pip install -U $outdated_pkg 2>&1 > /dev/null)

        # pip installでエラーが起きた場合はバージョンを戻す
        if [ -n "$update_error" ]; then
            docker exec $python_service_name pip install "${outdated_pkg}==${now_version}"
        fi
    done

    docker exec $python_service_name pip check
    status=$?

    # 依存関係が解消されない場合は全てを戻す
    if [ $status = 1 ]; then
        docker exec $python_service_name pip freeze | xargs pip uninstall -y
        for now_pkg in ${now_pkg_list[@]}; do
            docker exec $python_service_name pip install $now_pkg
        done
    fi
done
