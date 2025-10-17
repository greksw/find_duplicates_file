#!/bin/bash

# Скрипт поиска дубликатов по имени, размеру и хэшу для TrueNAS Core
SEARCH_DIR="${1:-/mnt/data/Exchange}"
OUTPUT_FILE="${2:-/tmp/duplicates_report_$(date +%Y%m%d_%H%M%S).txt}"
MAX_DEPTH="${3:-10}"

echo "=== ПОИСК ДУБЛИКАТОВ: имя, размер, хэш ==="
echo "Директория: $SEARCH_DIR"
echo "Результат: $OUTPUT_FILE"
echo "Макс. глубина: $MAX_DEPTH"
echo ""

{
    echo "ОТЧЕТ О ДУБЛИКАТАХ ФАЙЛОВ"
    echo "Дата создания: $(date)"
    echo "Директория поиска: $SEARCH_DIR"
    echo "Критерии: имя файла, размер, MD5 хэш"
    echo "=============================================="
    echo ""

    # Временные файлы
    TEMP_ALL_FILES=$(mktemp)
    TEMP_NAME_SIZE_DUPLICATES=$(mktemp)
    TEMP_HASH_CANDIDATES=$(mktemp)
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
        echo "$filename|$size|$mtime|$dirname|$file" >> "$TEMP_ALL_FILES"
    done

    total_files=$counter
    echo "Всего файлов: $total_files"
    echo ""

    echo "2. ПОИСК ДУБЛИКАТОВ ПО ИМЕНИ И РАЗМЕРУ..."
    echo "----------------------------------------"

    # Дубликаты по имени и размеру
    awk -F'|' '
    {
        name = $1
        size = $2
        mtime = $3
        dir = $4
        path = $5
        
        key = name "|" size
        if (keys[key]) {
            if (!printed[key]) {
                print "\nДУБЛИКАТЫ ПО ИМЕНИ И РАЗМЕРУ: \"" name "\" (" size " байт)"
                print "Первый файл: " first_path[key] " (Дата: " first_mtime[key] ")"
                printed[key] = 1
            }
            print "Дубликат: " path " (Дата: " mtime ")"
        } else {
            keys[key] = 1
            first_path[key] = path
            first_mtime[key] = mtime
        }
    }' "$TEMP_ALL_FILES" > "$TEMP_NAME_SIZE_DUPLICATES"

    name_size_dups=$(grep -c "ДУБЛИКАТЫ ПО ИМЕНИ И РАЗМЕРУ" "$TEMP_NAME_SIZE_DUPLICATES" || echo "0")
    echo "Найдено групп дубликатов по имени и размеру: $name_size_dups"
    echo ""

    echo "3. ПРОВЕРКА ДУБЛИКАТОВ ПО ХЭШУ (MD5)..."
    echo "----------------------------------"

    # Собираем все файлы, которые являются дубликатами по имени и размеру
    echo "Сбор файлов для проверки хэша..."
    
    # Извлекаем пути всех файлов-дубликатов
    grep "Дубликат: " "$TEMP_NAME_SIZE_DUPLICATES" | sed 's/Дубликат: //' | while read -r file; do
        # Также добавляем первый файл из каждой группы
        grep "Первый файл: " "$TEMP_NAME_SIZE_DUPLICATES" | sed 's/Первый файл: //' | awk '{print $1}' | while read -r first_file; do
            filename1=$(basename "$file")
            size1=$(get_size "$file")
            filename2=$(basename "$first_file")
            size2=$(get_size "$first_file")
            
            # Проверяем, что это файлы с одинаковым именем и размером
            if [ "$filename1" = "$filename2" ] && [ "$size1" = "$size2" ]; then
                echo "$first_file"
                echo "$file"
            fi
        done
    done | sort -u > "$TEMP_HASH_CANDIDATES"

    total_candidates=$(wc -l < "$TEMP_HASH_CANDIDATES" | tr -d ' ')
    echo "Файлов для проверки хэша: $total_candidates"
    echo "Вычисление хэшей..."

    # Вычисляем хэши для кандидатов
    while read -r file; do
        if [ -f "$file" ]; then
            hash=$(get_md5 "$file")
            if [ "$hash" != "ERROR" ]; then
                filename=$(basename "$file")
                size=$(get_size "$file")
                echo "$hash|$filename|$size|$file"
            fi
        fi
    done < "$TEMP_HASH_CANDIDATES" | sort > "$TEMP_HASH_DUPLICATES"

    # Группируем по хэшу и выводим результаты
    echo ""
    echo "=== ТОЧНЫЕ ДУБЛИКАТЫ (ПО ХЭШУ) ==="
    
    awk -F'|' '
    {
        hash = $1
        filename = $2
        size = $3
        path = $4
        
        if (hash == prev_hash) {
            if (!printed[hash]) {
                print "\nТОЧНЫЕ ДУБЛИКАТЫ (хэш: " hash ")"
                print "Файл: " filename " (" size " байт)"
                print "Первый файл: " first_path[hash]
                printed[hash] = 1
                count++
            }
            print "Дубликат: " path
        } else {
            prev_hash = hash
            first_path[hash] = path
        }
    }
    END {
        if (count > 0) {
            print "\nВсего групп точных дубликатов: " count
        } else {
            print "Точные дубликаты не найдены."
        }
    }' "$TEMP_HASH_DUPLICATES"

    hash_dups=$(awk -F'|' '
    {
        hash = $1
        if (hash == prev_hash && !printed[hash]) {
            count++
            printed[hash] = 1
        }
        prev_hash = hash
    }
    END { print count }' "$TEMP_HASH_DUPLICATES")

    echo ""
    echo "4. ФОРМИРОВАНИЕ ОТЧЕТА..."
    echo "-----------------------"

    # Объединяем все результаты
    echo "=== ДУБЛИКАТЫ ПО ИМЕНИ И РАЗМЕРУ ==="
    cat "$TEMP_NAME_SIZE_DUPLICATES"
    echo ""
    
    echo "=== ТОЧНЫЕ ДУБЛИКАТЫ (ПО ХЭШУ) ==="
    awk -F'|' '
    {
        hash = $1
        filename = $2
        size = $3
        path = $4
        
        if (hash == prev_hash) {
            if (!printed[hash]) {
                print "\nТОЧНЫЕ ДУБЛИКАТЫ (хэш: " hash ")"
                print "Файл: " filename " (" size " байт)"
                print "Первый файл: " first_path[hash]
                printed[hash] = 1
            }
            print "Дубликат: " path
        } else {
            prev_hash = hash
            first_path[hash] = path
        }
    }' "$TEMP_HASH_DUPLICATES"
    echo ""

    echo "=============================================="
    echo "СТАТИСТИКА:"
    echo "Всего файлов проверено: $total_files"
    echo "Дубликатов по имени и размеру: $name_size_dups групп"
    echo "Точных дубликатов (по хэшу): ${hash_dups:-0} групп"
    echo ""
    echo "Отчет сохранен: $OUTPUT_FILE"

    # Очистка временных файлов
    rm -f "$TEMP_ALL_FILES" "$TEMP_NAME_SIZE_DUPLICATES" "$TEMP_HASH_CANDIDATES" "$TEMP_HASH_DUPLICATES"

} 2>&1 | tee "$OUTPUT_FILE"

echo ""
echo "=== ЗАВЕРШЕНО ==="
echo "Полный отчет: $OUTPUT_FILE"
