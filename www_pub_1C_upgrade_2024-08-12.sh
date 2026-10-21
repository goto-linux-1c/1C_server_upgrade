#!/bin/bash

PROGNAME="$(basename "$0")"

usage() {
    echo -e "Использование программы: $PROGNAME параметр1 параметр2 \nПервый параметр это номер обновляемой версии 1С, если 0 то чистая установка \nВторой параметр это номер новой версии 1С"
    echo -e "Файл установки 1С должен находиться в одном каталоге со скриптом \nЕсли указан номер обновляемой версии 1С, то должен существовать каталог установки"
    echo "Пример: $PROGNAME 0 8.3.24.1586"
    echo "Пример: $PROGNAME 8.3.23.1586 8.3.24.1586"
    return
}
http_replace_version() {

    file_found=$(grep -ci "${old_version}" ${1})
    if [[ ${file_found} -gt 0 ]]; then
        echo "Изменяется версия в файле веб публикации ${1}"
        regular_exp="s/${old_version}/${new_version}/gi"
        perl -i"*_$(date +'%Y%m%d_%H%M%S').bak" -pE "${regular_exp}" ${1}
    fi
    return
}
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Скрипт должен быть запущен с правами администратора"
    exit 1
fi

#Проверить число аргументов
#если не 2 то вывести справку
if (($# != 2)); then
    usage
    exit 1
fi
old_version=$1
new_version=$2
current_date=$(date +'%Y%m%d_%H%M%S')

if [[ "${old_version}" != "0" ]]; then
    if [[ -d '/etc/httpd' ]]; then
        readarray -d '' -t find_files < <(find /etc/httpd -name '*.conf' -size +1c -type f -print0)
        for i in ${find_files[*]}; do http_replace_version $i; done

        echo 'Перезапускается веб сервер'
        systemctl restart httpd
    fi
fi
