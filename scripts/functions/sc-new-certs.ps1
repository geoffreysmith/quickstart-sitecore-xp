#  Copyright 2016 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
#  This file is licensed to you under the AWS Customer Agreement (the "License").
#  You may not use this file except in compliance with the License.
#  A copy of the License is located at http://aws.amazon.com/agreement/ .
#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied.
#  See the License for the specific language governing permissions and limitations under the License.

[CmdletBinding()]
param (
    [string]$StackName
)
#Certificate Requirments
$RootFriendlyName = (Get-SSMParameter -Name "/$StackName/cert/root/friendlyname").Value
$RootDNSNames = ((Get-SSMParameter -Name "/$StackName/cert/root/dnsnames").Value).Split(",").Trim()
$InstanceFriendlyName = (Get-SSMParameter -Name "/$StackName/cert/instance/friendlyname").Value
$InstanceDNSNames = ((Get-SSMParameter -Name "/$StackName/cert/instance/dnsnames").Value).Split(",").Trim()
$CertStoreLocation = (Get-SSMParameter -Name "/$StackName/cert/storelocation").Value
$RawPassword = (ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId "sitecore-quickstart-$StackName-certpass").SecretString).password
$ExportPassword = ConvertTo-SecureString $RawPassword -AsPlainText -Force
$ExportPath = (Get-SSMParameter -Name "/$StackName/user/localresourcespath").Value
$ExportRootCertName = (Get-SSMParameter -Name "/$StackName/cert/root/exportname").Value
$ExportInstanceCertName = (Get-SSMParameter -Name "/$StackName/cert/instance/exportname").Value
$S3BucketName = (Get-SSMParameter -Name "/$StackName/user/s3bucket/name").Value
$S3BucketCertificatePrefix = (Get-SSMParameter -Name "/$StackName/user/s3bucket/certificateprefix").Value

#Function to write to CloudWatch
function Write-LogsEntry {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string] $logGroupName,
        [Parameter(Mandatory = $true)]
        [string] $LogStreamName,
        [Parameter(Mandatory = $true)]
        [string] $LogString
    )
    Process {
        #Determine if the LogGroup Exists
        If (-Not (Get-CWLLogGroup -LogGroupNamePrefix $logGroupName)) {
            New-CWLLogGroup -LogGroupName $logGroupName
        }
        #Determine if the LogStream Exists
        If (-Not (Get-CWLLogStream -LogGroupName $logGroupName -LogStreamName $LogStreamName)) {
            $splat = @{
                LogGroupName  = $logGroupName
                LogStreamName = $logStreamName
            }
            New-CWLLogStream @splat
        }
        $logEntry = New-Object -TypeName 'Amazon.CloudWatchLogs.Model.InputLogEvent'
        $logEntry.Message = $LogString
        $logEntry.Timestamp = (Get-Date).ToUniversalTime()
        #Get the next sequence token
        $SequenceToken = (Get-CWLLogStream -LogGroupName $logGroupName -LogStreamNamePrefix $logStreamName).UploadSequenceToken
        if ($SequenceToken) {
            $splat = @{
                LogEvent      = $logEntry
                LogGroupName  = $logGroupName
                LogStreamName = $logStreamName
                SequenceToken = $SequenceToken
            }
            Write-CWLLogEvent @splat
        }
        else {
            $splat = @{
                LogEvent      = $logEntry
                LogGroupName  = $logGroupName
                LogStreamName = $logStreamName
            }
            Write-CWLLogEvent @splat
        }
    }
}
$logStreamName = "BaseImage-CertificateCreation" + (Get-Date (Get-Date).ToUniversalTime() -Format "MM-dd-yyyy" )

#Create new certificates
function NewCertificate {
    param(
        [string]$FriendlyName,
        [string[]]$DNSNames,
        [ValidateSet("LocalMachine", "CurrentUser")]
        [string]$CertStoreLocation = "LocalMachine",
        [ValidateScript( { $_.HasPrivateKey })]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Signer
    )

    # DCOM errors in System Logs are by design.
    # https://support.microsoft.com/en-gb/help/4022522/dcom-event-id-10016-is-logged-in-windows-10-and-windows-server-2016

    $date = Get-Date
    $certificateLocation = "Cert:\\$CertStoreLocation\My"
    $rootCertificateLocation = "Cert:\\$CertStoreLocation\Root"

    # Certificate Creation Location.
    $location = @{ }
    if ($CertStoreLocation -eq "LocalMachine") {
        $location.MachineContext = $true
        $location.Value = 2 # Machine Context
    }
    else {
        $location.MachineContext = $false
        $location.Value = 1 # User Context
    }

    # RSA Object
    $rsa = New-Object -ComObject X509Enrollment.CObjectId
    $rsa.InitializeFromValue(([Security.Cryptography.Oid]"RSA").Value)

    # SHA256 Object
    $sha256 = New-Object -ComObject X509Enrollment.CObjectId
    $sha256.InitializeFromValue(([Security.Cryptography.Oid]"SHA256").Value)

    # Subject
    $subject = "CN=Sitecore, O=AWS Quick Start, OU=Created by https://aws.amazon.com/quickstart/"
    $subjectDN = New-Object -ComObject X509Enrollment.CX500DistinguishedName
    $subjectDN.Encode($Subject, 0x0)

    # Subject Alternative Names
    $san = New-Object -ComObject X509Enrollment.CX509ExtensionAlternativeNames
    $names = New-Object -ComObject X509Enrollment.CAlternativeNames
    foreach ($sanName in $DNSNames) {
        $name = New-Object -ComObject X509Enrollment.CAlternativeName
        $name.InitializeFromString(3, $sanName)
        $names.Add($name)
    }
    $san.InitializeEncode($names)

    # Private Key
    $privateKey = New-Object -ComObject X509Enrollment.CX509PrivateKey
    $privateKey.ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider"
    $privateKey.Length = 2048
    $privateKey.ExportPolicy = 1 # Allow Export
    $privateKey.KeySpec = 1
    $privateKey.Algorithm = $rsa
    $privateKey.MachineContext = $location.MachineContext
    $privateKey.Create()

    # Certificate Object
    $certificate = New-Object -ComObject X509Enrollment.CX509CertificateRequestCertificate
    $certificate.InitializeFromPrivateKey($location.Value, $privateKey, "")
    $certificate.Subject = $subjectDN
    $certificate.NotBefore = ($date).AddDays(-1)

    if ($Signer) {
        # WebServer Certificate
        # WebServer Extensions
        $usage = New-Object -ComObject X509Enrollment.CObjectIds
        $keys = '1.3.6.1.5.5.7.3.2', '1.3.6.1.5.5.7.3.1' #Client Authentication, Server Authentication
        foreach ($key in $keys) {
            $keyObj = New-Object -ComObject X509Enrollment.CObjectId
            $keyObj.InitializeFromValue($key)
            $usage.Add($keyObj)
        }

        $webserverEnhancedKeyUsage = New-Object -ComObject X509Enrollment.CX509ExtensionEnhancedKeyUsage
        $webserverEnhancedKeyUsage.InitializeEncode($usage)

        $webserverBasicKeyUsage = New-Object -ComObject X509Enrollment.CX509ExtensionKeyUsage
        $webserverBasicKeyUsage.InitializeEncode([Security.Cryptography.X509Certificates.X509KeyUsageFlags]"DataEncipherment")
        $webserverBasicKeyUsage.Critical = $true

        # Signing CA cert needs to be in MY Store to be read as we need the private key.
        Move-Item -Path $Signer.PsPath -Destination $certificateLocation -Confirm:$false

        $signerCertificate = New-Object -ComObject X509Enrollment.CSignerCertificate
        $signerCertificate.Initialize($location.MachineContext, 0, 0xc, $Signer.Thumbprint)

        # Return the signing CA cert to the original location.
        Move-Item -Path "$certificateLocation\$($Signer.PsChildName)" -Destination $Signer.PSParentPath -Confirm:$false

        # Set issuer to root CA.
        $issuer = New-Object -ComObject X509Enrollment.CX500DistinguishedName
        $issuer.Encode($signer.Issuer, 0)

        $certificate.Issuer = $issuer
        $certificate.SignerCertificate = $signerCertificate
        $certificate.NotAfter = ($date).AddDays(730)
        $certificate.X509Extensions.Add($webserverEnhancedKeyUsage)
        $certificate.X509Extensions.Add($webserverBasicKeyUsage)

    }
    else {
        # Root CA
        # CA Extensions
        $rootEnhancedKeyUsage = New-Object -ComObject X509Enrollment.CX509ExtensionKeyUsage
        $rootEnhancedKeyUsage.InitializeEncode([Security.Cryptography.X509Certificates.X509KeyUsageFlags]"DigitalSignature,KeyEncipherment,KeyCertSign")
        $rootEnhancedKeyUsage.Critical = $true

        $basicConstraints = New-Object -ComObject X509Enrollment.CX509ExtensionBasicConstraints
        $basicConstraints.InitializeEncode($true, -1)
        $basicConstraints.Critical = $true

        $certificate.Issuer = $subjectDN #Same as subject for root CA
        $certificate.NotAfter = ($date).AddYears(10)
        $certificate.X509Extensions.Add($rootEnhancedKeyUsage)
        $certificate.X509Extensions.Add($basicConstraints)

    }

    $certificate.X509Extensions.Add($san) # Add SANs to Certificate
    $certificate.SignatureInformation.HashAlgorithm = $sha256
    $certificate.AlternateSignatureAlgorithm = $false
    $certificate.Encode()

    # Insert Certificate into Store
    $enroll = New-Object -ComObject X509Enrollment.CX509enrollment
    $enroll.CertificateFriendlyName = $FriendlyName
    $enroll.InitializeFromRequest($certificate)
    $certificateData = $enroll.CreateRequest(1)
    $enroll.InstallResponse(2, $certificateData, 1, "")

    # Retrieve thumbprint from $certificateData
    $certificateByteData = [System.Convert]::FromBase64String($certificateData)
    $createdCertificate = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2
    $createdCertificate.Import($certificateByteData)

    # Locate newly created certificate.
    $newCertificate = Get-ChildItem -Path $certificateLocation | Where-Object { $_.Thumbprint -Like $createdCertificate.Thumbprint }

    # Move CA to root store.
    if (!$Signer) {
        Move-Item -Path $newCertificate.PSPath -Destination $rootCertificateLocation
        $newCertificate = Get-ChildItem -Path $rootCertificateLocation | Where-Object { $_.Thumbprint -Like $createdCertificate.Thumbprint }
    }

    return $newCertificate
}

#Export Certificates
function ExportCert {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingConvertToSecureStringWithPlainText", "")]
    param (
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert,
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$Name = 'certificate',
        [switch]$IncludePrivateKey,
        [securestring]$Password
    )
    $CertificatePath = $path+'\certificates'
    if (-not (Test-Path -LiteralPath $CertificatePath)) {
        New-Item -Path $CertificatePath -ItemType Directory
    }

    $params = @{
        Cert = $Cert
    }

    $return = @{ }

    if ($IncludePrivateKey) {
        if (!$Password) {
            $pass = Invoke-RandomStringConfigFunction -Length 20 -EnforceComplexity
            Write-Information -MessageData "Password used for encryption: $pass" -InformationAction "Continue"
            $params.Password = ConvertTo-SecureString -String $pass -AsPlainText -Force
        }
        else {
            $params.Password = $Password
        }

        $params.FilePath = "$CertificatePath\$Name.pfx"

        Export-PfxCertificate @params
        $return.certname = "$Name.pfx"

    }
    else {

        $params.FilePath = "$CertificatePath\$Name.crt"

        Export-Certificate @params
        $return.certname = "$Name.crt"
    }

    Write-Information -MessageData "Exported certificate file $($params.FilePath)" -InformationAction 'Continue'
    $return.localPath = $params.FilePath

    return $return
}

function ValidateCertificate {
    Param (
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert
    )

    Write-Verbose -Message "Checking certificate $($Cert.Thumbprint) for validity."

    if ((Test-Certificate -Cert $Cert -AllowUntrustedRoot -ErrorAction:SilentlyContinue) -eq $false) {
        Write-Verbose -Message "Certificate rejected by Test-Certificate."
        return $false
    }

    if ($Cert.HasPrivateKey -eq $false) {
        Write-Verbose -Message "Certificate has no private key."
        return $false
    }

    Write-Verbose -Message "Certificate is OK."
    return $true

}

function CopyToS3Bucket {
    param (
        [String]$BucketName,
        [String]$BucketPrefix,
        [String]$ObjectName,
        [String]$LocalFileName
    )

    $key = $bucketPrefix + $objectName
    Write-S3Object -BucketName $bucketName -File $localFileName -Key $key

    Return "$bucketName\$key"
}

function WriteToParameterStore {
    Param (
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert
    )
    Write-SSMParameter -Name "/$stackName/cert/instance/thumbprint" -Type "String" -Value $cert.Thumbprint
}

#Creates the RootCA, moves it to Cert:\LocalMachine\Root and validates that it is correct (Returns True)
$root = NewCertificate `
    -FriendlyName $RootFriendlyName `
    -DNSNames $RootDNSNames `
    -CertStoreLocation $CertStoreLocation `

$ValidateRootCA = ValidateCertificate -Cert $root
$ExportRootCA = ExportCert -Cert $root -Path $ExportPath -Name $ExportRootCertName -IncludePrivateKey -Password $ExportPassword
$RootCAToS3 = CopyToS3Bucket -bucketName $S3BucketName -bucketPrefix $S3BucketCertificatePrefix -objectName $ExportRootCA.certname -localFileName $ExportRootCA.localPath

#Creates the Sitecore Instance cert based on the RootCA and validates that it is correct (Returns True)
$signedCertificate = NewCertificate `
    -FriendlyName $InstanceFriendlyName `
    -DNSNames $InstanceDNSNames `
    -Signer $root

WriteToParameterStore -Cert $signedCertificate

$ValidateInstanceCert = ValidateCertificate -Cert $signedCertificate
$exportinstanceCert = ExportCert -Cert $signedCertificate -Path $ExportPath -Name $ExportInstanceCertName -IncludePrivateKey -Password $ExportPassword
$InstanceCertToS3 = CopyToS3Bucket -bucketName $S3BucketName -bucketPrefix $S3BucketCertificatePrefix -objectName $exportinstanceCert.certname -localFileName $exportinstanceCert.localPath