#!/bin/bash

# Специальная версия для data/Exchange 702GB
SEARCH_DIR="/mnt/data/Exchange"
OUTPUT_FILE="/tmp/duplicates_exchange_$(date +%Y%m%d_%H%M%S).txt"
LOG_FILE="/tmp/duplicates_scan_$(date +%Y%m%d_%H%M%S).log"

echo "=== ПОИСК ДУБЛИКАТОВ: data/Exchange ==="
echo "Объем данных: 702GB"
echo "Компрессия: lz4"
echo "Дедупликация: off"
echo "Результаты: $OUTPUT_FILE"
echo "Лог: $LOG_FILE"
echo ""

{
    echo "Начало сканирования: $(date)"
    echo "Директория: $SEARCH_DIR"
    echo "Объем данных: 702GB"
    
    # Проверка доступности директории
    if [ ! -d "$SEARCH_DIR" ]; then
        echo "ОШИБКА: Директория $SEARCH_DIR не найдена!"
        exit 1
    fi
    
    # Временный файл для хэшей
    TEMP_HASHES=$(mktemp)
    echo "Временный файл: $TEMP_HASHES"
    
    # Счетчики
    counter=0
    echo "Подсчет файлов..."
    total_files=$(find "$SEARCH_DIR" -type f | wc -l)
    echo "Всего файлов: $total_files"
    
    echo "Начало хэширования: $(date)"
    
    # Оптимизированный поиск с прогресс-баром
    find "$SEARCH_DIR" -type f -print0 | while IFS= read -r -d '' file; do
        ((counter++))
        
        # Прогресс каждые 500 файлов
        if (( counter % 500 == 0 )); then
            percent=$(( counter * 100 / total_files ))
            echo "Прогресс: $counter/$total_files ($percent%) - $(date)"
        fi
        
        # Вычисляем MD5 хэш (FreeBSD)
        hash=$(md5 -q "$file" 2>/dev/null)
        size=$(stat -f%z "$file" 2>/dev/null)
        
        if [ -n "$hash" ] && [ -n "$size" ]; then
            echo "$hash $size $file" >> "$TEMP_HASHES"
        else
            echo "Ошибка: $file" >> "${LOG_FILE}.errors"
        fi
    done
    
    echo "Хэширование завершено: $(date)"
    echo "Поиск дубликатов..."
    
    # Сортировка и анализ
    sort "$TEMP_HASHES" | awk '
    BEGIN {
        group_count = 0
        duplicate_count = 0
        wasted_space = 0
        current_group = ""
        
        print "ДУБЛИКАТЫ ФАЙЛОВ - data/Exchange"
        print "Дата: " strftime("%Y-%m-%d %H:%M:%S")
        print "=============================================="
    }
    {
        hash = $1
        size = $2
        path = substr($0, index($0, $3))
        
        if (hash == prev_hash) {
            if (current_group != hash) {
                # Новая группа дубликатов
                group_count++
                current_group = hash
                print "\n" 
                print "ГРУППА #" group_count
                print "Хэш: " hash
                print "Размер: " size " байт"
                print "Файлы:"
                print prev_path
                duplicate_count++
                wasted_space += size
            }
            print path
            duplicate_count++
            wasted_space += size
        }
        
        prev_hash = hash
        prev_size = size
        prev_path = path
    }
    END {
        print "\n=============================================="
        print "ФИНАЛЬНАЯ СТАТИСТИКА:"
        print "Всего групп дубликатов: " group_count
        print "Всего файлов-дубликатов: " duplicate_count
        print "Потенциальная экономия места:"
        
        if (wasted_space >= 1099511627776) {
            printf "  %.2f TB\n", wasted_space / 1099511627776
        } else if (wasted_space >= 1073741824) {
            printf "  %.2f GB\n", wasted_space / 1073741824
        } else if (wasted_space >= 1048576) {
            printf "  %.2f MB\n", wasted_space / 1048576
        } else if (wasted_space >= 1024) {
            printf "  %.2f KB\n", wasted_space / 1024
        } else {
            print "  " wasted_space " байт"
        }
        
        if (total_files > 0) {
            duplicate_percent = (duplicate_count * 100) / (total_files + duplicate_count)
            printf "Дубликаты составляют: %.1f%% от всех файлов\n", duplicate_percent
        }
    }' total_files=$total_files > "$OUTPUT_FILE"
    
    # Очистка
    rm -f "$TEMP_HASHES"
    
    echo "Сканирование завершено: $(date)"
    
    # Финальная статистика
    echo ""
    echo "=== КРАТКАЯ СТАТИСТИКА ==="
    grep "ГРУППА #" "$OUTPUT_FILE" | tail -1
    grep "Всего групп" "$OUTPUT_FILE"
    grep "Потенциальная экономия" "$OUTPUT_FILE" | head -1
    
} 2>&1 | tee "$LOG_FILE"

echo ""
echo "=== ЗАВЕРШЕНО ==="
echo "Полные результаты: $OUTPUT_FILE"
echo "Детальный лог: $LOG_FILE"
