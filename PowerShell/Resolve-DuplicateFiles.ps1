$recycleBin="z:\DeletedFromPowerShell"

$hashesCache=$null
$newCachedHashes=0
$hashesCacheFile="c:\1\NAS\hashes-cache.xml"
$csvPath="c:\1\NAS\FilesCsv\"

function Get-FilesInDirectories{
    [CmdletBinding()]Param(
        [string] $Directory,
        [boolean] $Force
    )
    $csvFile=$csvPath + $Directory.Replace(":","_").Replace("\","_") + ".csv"
    if ($Force -or !(Test-Path -Path $csvFile)){
        Write-Host "Рекурсивная запись списка файлов в папке $Directory в файл $csvFile"
        Get-ChildItem $Directory -rec | where {!$_.PSIsContainer} | Select-Object Directory, Name, LastWriteTime, Length | Export-Csv -notypeinformation -delimiter '|' -path $csvFile -Encoding UTF8
    }
    
    Write-Host "Чтение списка файлов в папке $Directory из файла $csvFile"
    Import-Csv -Path $csvFile -Delimiter '|'
}

function Save-HashesCache{
    if ($global:newCachedHashes -eq 0) {
        return
    }
    Write-Host -ForegroundColor Green "Сохранение кэша хэшей ($($hashesCache.Count)) в $hashesCacheFile"
    $global:hashesCache | Export-Clixml $hashesCacheFile
}

function Get-Hash(){
    [CmdletBinding()]Param(
        [string] $File
    )

    if ($null -eq $global:hashesCache){
        if (Test-Path -Path $global:hashesCacheFile){            
            $global:hashesCache = Import-Clixml $global:hashesCacheFile
            Write-Verbose "Импорт кэша хэшей из файла. Count=$($global:hashesCache.Count)"
        } else {
            $global:hashesCache = @{}
        }
    }

    if ($global:hashesCache.ContainsKey($File)){
        Write-Verbose "Хэш $($global:hashesCache[$File]) файла '$File' найден в кэше"
        return $global:hashesCache[$File]
    }

    $hash=Get-FileHash -LiteralPath $File -Algorithm SHA256

    if ($Null -eq $hash){
        Write-Verbose "!!!!!!!"
    }

    $global:hashesCache[$File]=$hash.Hash
    Write-Verbose "Хэш $($global:hashesCache[$File]) файла '$File' рассчитан (newCachedHashes: $global:newCachedHashes)" 
       
    $global:newCachedHashes++
    if ($global:newCachedHashes -ge 100){
        Save-HashesCache
        $global:newCachedHashes=0
    }
    return $global:hashesCache[$File]
}

function Get-Hashes(){
    [CmdletBinding()]Param(
        [string[]] $Files
    )


    foreach ($file in $Files){
        Get-Hash -File $file
    }
}


function Get-ListOfPotentialDuplications{
    [CmdletBinding()]Param(
        [object] $SizesToFiles,
        [string] $Directory,
        [switch] $Sorted,
        [switch] $Force
    )
    $csv=Get-FilesInDirectories -Directory $Directory -Force:$Force

    $i=1
    $rowsCount=$csv.Count
    foreach ($row in $csv){
        if ($row.Directory.Contains("\#recycle\")){
            continue
        }
        if ($row.Directory.ToLower().StartsWith($recycleBin.ToLower())){
            continue
        }
        $key=$row.Length 
        if ($SizesToFiles.ContainsKey($key)){
            Write-Host "$i\$rowsCount Дубль $key в $($SizesToFiles["$key"].Directory) и $($row.Directory)"
        } else {
            $SizesToFiles[$key]=@{}
            $SizesToFiles[$key].Files=@()
        }
        $file=@{}
        $file.Directory=$row.Directory
        $file.Name=$row.Name
        $file.FullName=$row.Directory + "\" + $row.Name
        $file.Length=$row.Length
        $file.LastWriteTime=$row.LastWriteTime
        $file.Sorted=$Sorted
        $SizesToFiles[$key].Files+=$file
        $i++
    }
}

function Get-HashesOfPotentialDuplications{
    [CmdletBinding()]Param(
        [object] $SizesToFiles,
        [object] $HashesToFiles
    )

    $i=0
    $cnt=$SizesToFiles.Keys.Count
    foreach ($size in $SizesToFiles.Keys){
        $i++
        if ($SizesToFiles[$size].Files.Count -le 1){
            continue
        }
        foreach ($file in $SizesToFiles[$size].Files){
            $hash=Get-Hash -File $file.FullName
            if (!$HashesToFiles.ContainsKey($hash)){
                $HashesToFiles[$hash]=@{}
                $HashesToFiles[$hash].Files=@()
            }
            $HashesToFiles[$hash].Files+=$file
            $percent=[math]::round($i/$cnt*100,2)
            Write-Host "$i/$cnt".PadRight(13) -NoNewline
            Write-Host "$percent%".PadRight(9) -NoNewline
            Write-Host "$hash " -NoNewline
            Write-Host "$($file.Length)".PadRight(10) -NoNewline            
            Write-Host $file.FullName
        }        
    }

    Save-HashesCache
}

function Remove-SingleFiles{
    [CmdletBinding()]Param(
        [object] $HashesToFiles
    )
    
    $hashesToRemove=@()
    foreach ($hash in $HashesToFiles.Keys){
        if ($HashesToFiles[$hash].Files.Count -eq 1){
            $hashesToRemove+=$hash
        }
    }

    foreach ($hashToRemove in $hashesToRemove){
        $HashesToFiles.Remove($hashToRemove)
    }
}

function Group-DuplicateByDirectories{
    [CmdletBinding()]Param(
        [object] $HashesToFiles,
        [object] $DirectoriesToDuplicates
    )

    foreach($hash in $HashesToFiles.Keys){
        foreach ($file in $HashesToFiles[$hash].Files){
            if (!$DirectoriesToDuplicates.ContainsKey($file.Directory)){
                $DirectoriesToDuplicates[$file.Directory]=@{}
                $DirectoriesToDuplicates[$file.Directory].Hashes=@{}
            }
            $dirHashes=$DirectoriesToDuplicates[$file.Directory].Hashes
            if (!$dirHashes.ContainsKey($hash)){
                $dirHashes[$hash]=@{}
                $dirHashes[$hash].LocalFiles=@{}
                $dirHashes[$hash].Duplicates=@{}
            }

            foreach($fileWithHash in $HashesToFiles[$hash].Files){
                if ($file.Directory -eq $fileWithHash.Directory){
                    $dirHashes[$hash].LocalFiles[$fileWithHash.FullName]=$fileWithHash
                } else {
                    $dirHashes[$hash].Duplicates[$fileWithHash.FullName]=$fileWithHash
                }
            }
        }
    }
}

function Remove-Duplicate{
    [CmdletBinding()]Param(
        [object] $DirectoriesToDuplicates,
        [string] $File
    )

    Write-Host "Файл удален: $File"
    Move-Item -Path $File -Destination $recycleBin
}


function Resolve-DuplicatesByHash{
    [CmdletBinding()]Param(
        [object] $DirectoriesToDuplicates,
        [string] $Directory,
        [string] $Hash
    )
    $files=$DirectoriesToDuplicates[$dir].Hashes[$Hash]
    Write-Host -ForegroundColor White "    $hash $Directory"
    $localFiles=$hashes[$hash].LocalFiles.GetEnumerator()
    $duplicates=$hashes[$hash].Duplicates.GetEnumerator()

    $fileIndex=1
    $indexesToFiles=@{}
    while ($True) {
        $hasLocalFile=$localFiles.MoveNext()
        $hasDuplicate=$duplicates.MoveNext()
        if (!$hasLocalFile -and !$hasDuplicate) {
            break
        }
                
        if ($hasLocalFile){
            $indexesToFiles[$fileIndex]=$localFiles.Current.Value.FullName                        
            $localFile=$localFiles.Current.Value.Name.PadRight(70)                    
            Write-Host -ForegroundColor Red "[$fileIndex] " -NoNewline
            $fileIndex++
        } else {
            $localFile="".PadRight(70)
        }
        Write-Host -ForegroundColor Magenta " $localFile " -NoNewline

        if ($hasDuplicate){
            $indexesToFiles[$fileIndex]=$duplicates.Current.Value.FullName            
            $duplicate=$duplicates.Current.Value.FullName                 
            Write-Host -ForegroundColor Red "[$fileIndex] " -NoNewline
            $fileIndex++   
        } else {
            $duplicate=""
        }
        Write-Host -ForegroundColor Cyan " $duplicate "
    }

    Write-Host -ForegroundColor White ""
    $key = Read-Host "Введите номер файла, который надо оставить (удалив остальные)"
    if ($key -eq ''){
        Write-Host "Пропускаем"
        Read-Host
        return
    }

    $selectedIndex=[int]$key
    $ignoreFile=$indexesToFiles[$selectedIndex]
    $filesToDelete=@()
    for ($i=1;$i -lt $fileIndex; $i++){
        if ($i -eq $selectedIndex){
            continue
        }
        $filesToDelete+=$indexesToFiles[$i]
    }

    Write-Host "Вы выбрали файл [$selectedIndex] $ignoreFile. Следующие файлы будут удалены:"
    foreach($fileToDelete in $filesToDelete){
        Write-Host "    $fileToDelete"
    }
    $key=Read-Host "Подтверждаете удаление [y|n]"
    if ($key -eq 'y'){
        foreach($fileToDelete in $filesToDelete){
            Remove-Duplicate -DirectoriesToDuplicates $DirectoriesToDuplicates -File $fileToDelete
        }
        Read-Host
    }
}


function Show-Duplicates{
    [CmdletBinding()]Param(
        [object] $HashesToFiles
    )

    $i=1
    foreach($hash in $HashesToFiles.Keys){
        $j=1
        foreach ($file in $HashesToFiles[$hash].Files){
            $foreColor="Gray" -as [System.ConsoleColor]
            if ($j -eq 1){
                $foreColor = "White" -as [System.ConsoleColor]
            }
            Write-Host -ForegroundColor $foreColor "$i.$j $hash $($file.FullName)"
            $j++
        }
        $i++
    }
}

function Show-DuplicatesByFolders{
    [CmdletBinding()]Param(
        [object] $DirectoriesToDuplicates,
        [switch] $Interactive
    )

    $i=1
    $cnt=$DirectoriesToDuplicates.Count
    foreach($dir in $DirectoriesToDuplicates.Keys){
        Write-Host -ForegroundColor White "$i $dir"
        $hashes=$DirectoriesToDuplicates[$dir].Hashes
        foreach($hash in $hashes.Keys){
            Write-Host -ForegroundColor Gray "    $hash" -NoNewline
            $localFiles=$hashes[$hash].LocalFiles.GetEnumerator()
            $duplicates=$hashes[$hash].Duplicates.GetEnumerator()
            
#            $max=$localFiles.Count
#            if ($duplicates.Count -gt $max){
#                $max=$duplicates.Count
#            }
            $rowIndex=0
            while ($True) {
                $hasLocalFile=$localFiles.MoveNext()
                $hasDuplicate=$duplicates.MoveNext()
                if (!$hasLocalFile -and !$hasDuplicate) {
                    break
                }

                if ($rowIndex -gt 0){
                    Write-Host "".PadRight(68) -NoNewline
                }

                
                if ($hasLocalFile){
                    $localFile=$localFiles.Current.Value.Name.PadRight(70)                    
                } else {
                    $localFile="".PadRight(70)
                }
                Write-Host -ForegroundColor Magenta " $localFile " -NoNewline

                if ($hasDuplicate){
                    $duplicate=$duplicates.Current.Value.FullName                    
                } else {
                    $duplicate=""
                }
                Write-Host -ForegroundColor Cyan " $duplicate "
                $rowIndex++
            }
        }

        if ($Interactive){
            Write-Host "[h] - разрешить пофайлово, [y] - удалить все дубли файлов папки '$dir' в других папках? [y|h|n]"
            $key = Read-Host
            if ($key -eq 'y') {
                $filesToDelete=@()
                foreach($hash in $hashes.Keys){
                    foreach ($duplicate in $hashes[$hash].Duplicates.Keys){                        
                        $filesToDelete+=$duplicate
                    }
                }

                foreach ($fileToDelete in $filesToDelete){
                    Write-Host "Удаление $fileToDelete"

                    Move-Item -Path $fileToDelete -Destination $recycleBin
                }
            } elseif ($key -eq 'h') {
                foreach($hash in $hashes.Keys){
                    cls
                    Resolve-DuplicatesByHash -DirectoriesToDuplicates $DirectoriesToDuplicates -Directory $dir -Hash $hash
                }
            }
            cls
        }

        $i++
    }
}

cls
$sizesToFiles=@{}
$hashesToFiles=@{}
$dirsToDuplicates=@{}
Get-ListOfPotentialDuplications -SizesToFiles $sizesToFiles -Directory "z:\" -Sorted -Force
#Get-ListOfPotentialDuplications -SizesToFiles $sizesToFiles -Directory "q:\Отсортировано" -Sorted
#Get-ListOfPotentialDuplications -SizesToFiles $sizesToFiles -Directory "q:\_Сортировать"
Get-HashesOfPotentialDuplications -SizesToFiles $sizesToFiles -HashesToFiles $hashesToFiles
Remove-SingleFiles -HashesToFiles $hashesToFiles
#Show-Duplicates -HashesToFiles $hashesToFiles
Group-DuplicateByDirectories -HashesToFiles $hashesToFiles -DirectoriesToDuplicates $dirsToDuplicates
Show-DuplicatesByFolders -DirectoriesToDuplicates $dirsToDuplicates
