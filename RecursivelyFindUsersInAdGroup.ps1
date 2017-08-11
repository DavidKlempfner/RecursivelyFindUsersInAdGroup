<#
.SYNOPSIS
    This script outputs all members in an AD group (including all nested groups).

.DESCRIPTION
    This script outputs all members in an AD group (including all nested groups).
    Recursion is used to get all nested groups' members.

    Pseudo code:

    Get all members of group    
    Foreach member of the group
        Is it not a group? (ie. is it a computer/user)
            Yes: 
                Store the name in a variable
                Store the object type class (computer/user)
            No:
                Call this function again

.INPUTS
    The parent AD group's distinguished name ($GroupDistinguishedName)
    The properties to load from AD ($PropertiesToLoad)

.OUTPUTS
    A list of PSCustomObjects

.EXAMPLE
    
.NOTES
    Author: dklempfner@gmail.com
    Date: 29/06/2017

    Updates:
    Date: 02/08/2017
    Now checking cross domain groups (ie mno groups).
#>

Param([String]$GroupDistinguishedName = 'CN=SomeGroupName,OU=Application Groups,OU=Groups,OU=Abc,DC=Def,DC=Ghi,DC=Jkl,DC=AU',
      [Object[]]$PropertiesToLoad  = @('objectclass', 'member', 'name', 'distinguishedname'))

function GetDirectorySearcher
{
    param([Parameter(Mandatory=$true)][String]$LdapPath,
          [Parameter(Mandatory=$false)][Object[]]$Properties)
        
    $directoryEntry = New-Object 'System.DirectoryServices.DirectoryEntry'    
    $directoryEntry.Path = $LdapPath
    $searcher = New-Object 'System.DirectoryServices.DirectorySearcher'($directoryEntry)
    $searcher.SearchScope = [System.DirectoryServices.SearchScope]::SubTree    
    $searcher.PageSize = [System.Int32]::MaxValue
    
    if($Properties)
    {
        foreach($property in $Properties)
        {
            $searcher.PropertiesToLoad.Add($property) | Out-Null
        }
    }
    
    return $searcher
}

function GetNestingLevel
{
    param([Parameter(Mandatory=$true)][String]$NestedGroupNames,
          [Parameter(Mandatory=$true)][String]$Delimeter)

    $nestedGroupNamesSplitByDelimeter = $NestedGroupNames.Split($Delimeter, [System.StringSplitOptions]::None)
    $nestedGroupNamesSplitByDelimeterWithNoBlanks = $nestedGroupNamesSplitByDelimeter | Where-Object { $_ }
    $levelOfNesting = $nestedGroupNamesSplitByDelimeterWithNoBlanks.Count - 1

    return $levelOfNesting
}

function IsNameSid
{
    param([Parameter(Mandatory=$true)][String]$Name)

    $sidPattern = '^S-\d-\d+-(\d+-){1,14}\d+$'
    $isValidFormat = [Regex]::IsMatch($Name, $sidPattern)
    return $isValidFormat
}

function GetNameFromSid
{
    param([Parameter(Mandatory=$true)][String]$Sid)

    $objSid = New-Object 'System.Security.Principal.SecurityIdentifier'($Sid)
    $objUser = $objSid.Translate([System.Security.Principal.NTAccount])
    return $objUser.Value
}

function RemoveDomainNameFromStartOfName
{
    param([Parameter(Mandatory=$true)][String]$Name)

    $indexOfSlash = $Name.IndexOf('\')
    $startIndex = $indexOfSlash + 1 
    $length = $Name.Length - $startIndex
    $nameWithDomainNameRemoved = $Name.Substring($startIndex, $length)
    return $nameWithDomainNameRemoved
}

function GetObjectClass
{
    param([Parameter(Mandatory=$false)][System.DirectoryServices.ResultPropertyValueCollection]$ObjectClasses)
    if(!$ObjectClasses)
    {
        return 'mno USER'
    }
    $lastElementInArray = $ObjectClasses.Count-1
    $objectClass = $objectClasses[$lastElementInArray]
    return $objectClass
}

function CreateListOfMembers
{
    param([Parameter(Mandatory=$true)][System.DirectoryServices.ResultPropertyValueCollection]$Members,
          [Parameter(Mandatory=$true)][Object[]]$PropertiesToLoad,
          [Parameter(Mandatory=$true)][String]$NestedGroupNames,
          [Parameter(Mandatory=$false)][System.Collections.Generic.List[PSCustomObject]]$ListOfMembers)
    
    $delimeter = '|'

    foreach($distinguishedName in $members)
    {
        $memberLdapPath = "LDAP://$distinguishedName"
        $tempDirSearcher = GetDirectorySearcher $memberLdapPath $PropertiesToLoad 
        $memberAdObject = $tempDirSearcher.FindOne()

        if($memberAdObject -and $memberAdObject.Properties.name.Count -gt 0)
        {
            $name = $memberAdObject.Properties.name[0]
            $isNameSid = IsNameSid $name
            if($isNameSid)
            {
                $name = GetNameFromSid $name
                $name = RemoveDomainNameFromStartOfName $name
                $distinguishedName = "CN=$name,OU=Applications,DC=mno,DC=Jkl,DC=AU"
                $memberLdapPath = "LDAP://$distinguishedName"
                $tempDirSearcher = GetDirectorySearcher $memberLdapPath $PropertiesToLoad
                $memberAdObject = $null
                try
                {
                    $memberAdObject = $tempDirSearcher.FindAll()
                }
                catch
                {
                    $errorMsg = $_.Exception.Message
                    Write-Warning "Tried searching for a group called $name. It's probably a user on another domain and not a group - $errorMsg"
                }
            }

            $objectClass = GetObjectClass $memberAdObject.Properties.objectclass
            $isMemberOfTypeGroup = $objectClass.ToUpper() -eq 'GROUP'

            if($isMemberOfTypeGroup)
            {
                #This prevents an infinite loop in case a parent group is a member of a child group:
                if($NestedGroupNames.Contains($distinguishedName)) 
                {
                    continue
                }
                $newNestedGroupNames = "$distinguishedName$delimeter$NestedGroupNames"
                if($memberAdObject.Properties.member)
                {
                    CreateListOfMembers $memberAdObject.Properties.member $PropertiesToLoad $newNestedGroupNames $ListOfMembers
                }
            }
            else
            {            
                $levelOfNesting = GetNestingLevel $NestedGroupNames $delimeter
                $customObject = [PSCustomObject]@{Name = $name; LevelOfNesting = $LevelOfNesting; NestedGroupNames = $NestedGroupNames; ObjectClass = $objectClass}
                $ListOfMembers.Add($customObject)
            }
        }
    }
}

cls


$ldapPath = "LDAP://$GroupDistinguishedName"
$listOfMembers = New-Object 'System.Collections.Generic.List[PSCustomObject]'
$directorySearcher = GetDirectorySearcher $LdapPath $propertiesToLoad
$result = $directorySearcher.FindOne()

CreateListOfMembers $result.Properties.member $PropertiesToLoad $GroupDistinguishedName $listOfMembers

#Output the custom objects:
$listOfMembers | Export-Csv 'C:\Temp\OutputFile.csv' -NoTypeInformation