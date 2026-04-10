# PowerShell Script to Create a Windows 11 Installer with VirtIO Drivers and Unattended Setup

# Variables
$BaseISO = "Win11_25H2_English_x64_v2.iso"
$VirtIODriversURL = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
$WorkingDir = "C:\Win11_Working"
$OutputISO = "Win11_Custom_Installer.iso"
$RandomPassword = [System.Web.Security.Membership]::GeneratePassword(12, 2)
$IPSettings = @{
    IPAddress = "192.168.1.100"  # Replace with your current IP
    SubnetMask = "255.255.255.0"
    Gateway = "192.168.1.1"
    DNS = "8.8.8.8"
}

# Step 1: Prepare Working Directory
Write-Host "Preparing working directory..."
New-Item -ItemType Directory -Force -Path $WorkingDir

# Step 2: Mount the Base ISO
Write-Host "Mounting the base ISO..."
$MountResult = Mount-DiskImage -ImagePath $BaseISO -PassThru
$MountedDrive = ($MountResult | Get-Volume).DriveLetter

# Step 3: Copy ISO Contents to Working Directory
Write-Host "Copying ISO contents to working directory..."
Copy-Item -Path "$MountedDrive\*" -Destination $WorkingDir -Recurse

# Step 4: Download and Extract VirtIO Drivers
Write-Host "Downloading VirtIO drivers..."
$VirtIOISO = "$WorkingDir\virtio-win.iso"
Invoke-WebRequest -Uri $VirtIODriversURL -OutFile $VirtIOISO
Write-Host "Extracting VirtIO drivers..."
Mount-DiskImage -ImagePath $VirtIOISO -PassThru | ForEach-Object {
    $VirtIODrive = ($_ | Get-Volume).DriveLetter
    Copy-Item -Path "$VirtIODrive\*" -Destination "$WorkingDir\VirtIO" -Recurse
    Dismount-DiskImage -ImagePath $VirtIOISO
}

# Step 5: Create Unattended Answer File
Write-Host "Creating unattended answer file..."
$UnattendXML = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserData>
        <ProductKey>
          <Key>XXXXX-XXXXX-XXXXX-XXXXX-XXXXX</Key>
        </ProductKey>
        <AcceptEula>true</AcceptEula>
        <FullName>Administrator</FullName>
        <Organization>Contabo</Organization>
      </UserData>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/INDEX</Key>
              <Value>1</Value>
            </MetaData>
          </InstallFrom>
        </OSImage>
      </ImageInstall>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <AutoLogon>
        <Password>
          <Value>$RandomPassword</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
      </AutoLogon>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>$RandomPassword</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
"@
$UnattendPath = "$WorkingDir\autounattend.xml"
$UnattendXML | Out-File -FilePath $UnattendPath -Encoding utf8

# Step 6: Rebuild the ISO
Write-Host "Rebuilding the ISO..."
$ISOCommand = "oscdimg -m -o -u2 -udfver102 -lWIN11_CUSTOM -bootdata:2#p0,e,b$WorkingDir\boot\etfsboot.com#$pEF,e,b$WorkingDir\efi\microsoft\boot\efisys.bin $WorkingDir $OutputISO"
Invoke-Expression $ISOCommand

# Step 7: Cleanup
Write-Host "Cleaning up..."
Dismount-DiskImage -ImagePath $BaseISO

Write-Host "Custom Windows 11 installer created: $OutputISO"