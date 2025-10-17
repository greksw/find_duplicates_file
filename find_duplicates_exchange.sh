#!/bin/bash

# Скрипт поиска дубликатов по имени, дате и хэшу для TrueNAS Core
SEARCH_DIR="${1:-/mnt/data/Exchange}"
OUTPUT_FILE="${2:-/tmp/duplicates_report_$(date +%Y%m%d_%H%M%S).txt}"
MAX_DEPTH="${3:-10}"

echo "=== ПОИСК ДУБЛИКАТОВ: имя, дата, хэш ==="
echo "Директория: $SEARCH_DIR"
echo "Результат: $OUTPUT_FILE"
echo "Макс. глубина: $MAX_DEPTH"
echo ""

{
    echo "ОТЧЕТ О ДУБЛИКАТАХ ФАЙЛОВ"
    echo "Дата создания: $(date)"
    echo "Директория поиска: $SEARCH_DIR"
    echo "Критерии: имя файла, дата модификации, MD5 хэш"
    echo "=============================================="
    echo ""

    # Временные файлы
    TEMP_ALL_FILES=$(mktemp)
    TEMP_NAME_DUPLICATES=$(mktemp)
    TEMP_DATE_DUPLICATES=$(mktemp)
    TEMP_HASH_DUPLICATES=$(mktemp)

    # Функция для получения MD5 хэша (FreeBSD)
    get_md5() {
        local file="$1"
        if command -v md5 >/dev/null 2>&1; then
            md5 -q "$file" 2>/dev/null || echo "ERROR"
        else
            md5sum "$file" 2>/dev/null | awk '{print $1}' || echo "ERROR"
        fi
    }

    # Функция для получения даты модификации
    get_mtime() {
        local file="$1"
        stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null || echo "UNKNOWN"
    }

    # Функция для получения размера
    get_size() {
        local file="$1"
        stat -f%z "$file" 2>/dev/null || echo "0"
    }

    echo "1. СБОР ИНФОРМАЦИИ О ФАЙЛАХ..."
    echo "----------------------------"

    # Находим все файлы и собираем информацию
    counter=0
    find "$SEARCH_DIR" -type f -maxdepth "$MAX_DEPTH" -print0 | while IFS= read -r -d '' file; do
        ((counter++))
        if (( counter % 500 == 0 )); then
            echo "Обработано файлов: $counter"
        fi
        
        filename=$(basename "$file")
        dirname=$(dirname "$file")
        mtime=$(get_mtime "$file")
        size=$(get_size "$file")
        
        # Записываем информацию о файле
        echo "$filename|$mtime|$size|$dirname|$file" >> "$TEMP_ALL_FILES"
    done

    total_files=$counter
    echo "Всего файлов: $total_files"
    echo ""

    echo "2. ПОИСК ДУБЛИКАТОВ ПО ИМЕНИ ФАЙЛА..."
    echo "-----------------------------------"

    # Дубликаты по имени
    awk -F'|' '
    {
        name = $1
        mtime = $2
        size = $3
        dir = $4
        path = $5
        
        if (names[name]) {
            if (!printed[name]) {
                print "\nДУБЛИКАТЫ ПО ИМЕНИ: \"" name "\""
                print "Первый файл: " first_path[name]
                printed[name] = 1
            }
            print "Дубликат: " path " (Дата: " mtime ", Размер: " size ")"
        } else {
            names[name] = 1
            first_path[name] = path
        }
    }' "$TEMP_ALL_FILES" > "$TEMP_NAME_DUPLICATES"

    name_dups=$(grep -c "ДУБЛИКАТЫ ПО ИМЕНИ" "$TEMP_NAME_DUPLICATES" || echo "0")
    echo "Найдено групп дубликатов по имени: $name_dups"
    echo ""

    echo "3. ПОИСК ДУБЛИКАТОВ ПО ДАТЕ И РАЗМЕРУ..."
    echo "--------------------------------------"

    # Дубликаты по дате и размеру (быстрая проверка)
    awk -F'|' '
    {
        name = $1
        mtime = $2
        size = $3
        dir = $4
        path = $5
        
        key = mtime "|" size
        if (dates[key]) {
            if (!printed[key]) {
                print "\nДУБЛИКАТЫ ПО ДАТЕ/РАЗМЕРУ: " mtime " (" size " байт)"
                print "Первый файл: " first_path[key]
                printed[key] = 1
            }
            print "Дубликат: " path " (Имя: " name ")"
        } else {
            dates[key] = 1
            first_path[key] = path
        }
    }' "$TEMP_ALL_FILES" > "$TEMP_DATE_DUPLICATES"

    date_dups=$(grep -c "ДУБЛИКАТЫ ПО ДАТЕ/РАЗМЕРУ" "$TEMP_DATE_DUPLICATES" || echo "0")
    echo "Найдено групп дубликатов по дате/размеру: $date_dups"
    echo ""

    echo "4. ПОИСК ДУБЛИКАТОВ ПО ХЭШУ (MD5)..."
    echo "----------------------------------"

    # Дубликаты по хэшу (только для потенциальных кандидатов)
    echo "Вычисление хэшей для файлов-кандидатов..."
    
    # Собираем файлы которые могут быть дубликатами по дате/размеру
    awk -F'|' '
    {
        mtime = $2
        size = $3
        path = $5
        
        key = mtime "|" size
        count[key]++
        if (count[key] > 1) {
            print path
        }
    }' "$TEMP_ALL_FILES" | while read -r file; do
        hash=$(get_md5 "$file")
        if [ "$hash" != "ERROR" ]; then
            echo "$hash|$file"
        fi
    done | sort | awk -F'|' '
    {
        hash = $1
        path = $2
        
        if (hash == prev_hash) {
            if (!printed[hash]) {
                print "\nДУБЛИКАТЫ ПО ХЭШУ: " hash
                print "Первый файл: " first_path[hash]
                printed[hash] = 1
            }
            print "Дубликат: " path
        } else {
            prev_hash = hash
            first_path[hash] = path
        }
    }' > "$TEMP_HASH_DUPLICATES"

    hash_dups=$(grep -c "ДУБЛИКАТЫ ПО ХЭШУ" "$TEMP_HASH_DUPLICATES" || echo "0")
    echo "Найдено групп дубликатов по хэшу: $hash_dups"
    echo ""

    echo "5. ФОРМИРОВАНИЕ ОТЧЕТА..."
    echo "-----------------------"

    # Объединяем все результаты
    echo "=== ДУБЛИКАТЫ ПО ИМЕНИ ФАЙЛА ==="
    cat "$TEMP_NAME_DUPLICATES"
    echo ""
    
    echo "=== ДУБЛИКАТЫ ПО ДАТЕ И РАЗМЕРУ ==="
    cat "$TEMP_DATE_DUPLICATES"
    echo ""
    
    echo "=== ДУБЛИКАТЫ ПО ХЭШУ (MD5) ==="
    cat "$TEMP_HASH_DUPLICATES"
    echo ""

    echo "=============================================="
    echo "СТАТИСТИКА:"
    echo "Всего файлов проверено: $total_files"
    echo "Дубликатов по имени: $name_dups групп"
    echo "Дубликатов по дате/размеру: $date_dups групп"
    echo "Дубликатов по хэшу: $hash_dups групп"
    echo ""
    echo "Отчет сохранен: $OUTPUT_FILE"

    # Очистка временных файлов
    rm -f "$TEMP_ALL_FILES" "$TEMP_NAME_DUPLICATES" "$TEMP_DATE_DUPLICATES" "$TEMP_HASH_DUPLICATES"

} 2>&1 | tee "$OUTPUT_FILE"

echo ""
echo "=== ЗАВЕРШЕНО ==="
echo "Полный отчет: $OUTPUT_FILE"
