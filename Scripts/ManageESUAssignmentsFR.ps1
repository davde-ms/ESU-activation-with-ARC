<# 
//-----------------------------------------------------------------------

CE SCRIPT EST FOURNI "TEL QUEL" SANS AUCUNE GARANTIE D'AUCUNE SORTE ET NE DOIT ÊTRE UTILISÉ QUE POUR DES TESTS OU DES DÉMONSTRATIONS.
VOUS ÊTES LIBRE DE RÉUTILISER ET/OU MODIFIER LE CODE POUR RÉPONDRE À VOS BESOINS

//-----------------------------------------------------------------------

.SYNOPSIS
Gère les affectations de licences ESU en masse, en prenant ses entrées à partir d'un fichier CSV.

.DESCRIPTION
Ce script gère l'affectation des licences ESU basées sur ARC pour les serveurs nécessitant une activation ESU.
Il récupère les informations d'un fichier CSV et de la ligne de commande pour des tâches comme l'affectation et la désaffectation de licences.
Son but est de vous permettre d'affecter une seule licence à plusieurs serveurs à la fois ou de supprimer le lien d'une licence de plusieurs serveurs à la fois.
Il prend en charge les scénarios inter-abonnements où les licences ESU peuvent être situées dans des abonnements différents de ceux des serveurs ARC.


Le script prend en charge deux méthodes d'authentification :
1. Authentification par principal de service (nécessite tenantId, appID et clientSecret)
2. Authentification par jeton utilisateur (nécessite un jeton d'authentification Microsoft Entra ID valide)

.NOTES
Nom du fichier : ManageESUAssignmentsFR.ps1
Auteur         : David De Backer
Version        : 1.4
Date           : 10-Octobre-2025  
Mise à jour    : 28-Octobre-2025
Testé sur      : PowerShell Version 7.3.8
Module         : Azure Powershell version 9.6.0
Exigences      : Powershell Core version 7.x ou ultérieure
Produit        : Azure ARC

.CHANGELOG
v1.0 - Version initiale
v1.1 - Ajout du support pour les affectations de licences inter-abonnements. Les licences ESU peuvent maintenant être situées dans des abonnements différents de ceux des serveurs ARC.
       Ajout de la rétrocompatibilité avec le format CSV existant.
       Ajout du paramètre optionnel -licenseSubscriptionId et de la colonne CSV LicenseSubscriptionId.
       La colonne CSV LicenseSubscriptionId a toujours la priorité sur le paramètre de ligne de commande lorsqu'elle est fournie.
v1.2 - Ajout du support pour l'authentification par jeton utilisateur. Vous pouvez maintenant fournir un jeton d'authentification Microsoft Entra ID au lieu des informations d'identification du principal de service.
       Les paramètres tenantId, appID et clientSecret sont maintenant optionnels lors de l'utilisation de l'authentification par jeton.
v1.3 - Améliorations majeures d'optimisation et de fiabilité :
       • Gestion d'erreurs améliorée avec journalisation détaillée et niveaux de gravité (INFO, WARNING, ERROR, SUCCESS)
       • Ajout de la validation complète des entrées pour les fichiers CSV et les vérifications d'intégrité des données
       • Implémentation du suivi de progression avec barre de progression en temps réel et compteurs d'opérations
       • Ajout du mode simulation (-DryRun parameter) pour tester sans apporter de modifications réelles
       • Authentification améliorée avec logique de nouvelle tentative et meilleure validation des jetons
       • Ajout de la fonction Test-CSVRowData pour valider chaque ligne CSV avant traitement
       • Amélioration de la fonction Write-Logfile avec sortie console codée par couleur
       • Ajout de constantes de configuration pour faciliter la maintenance et la gestion des versions d'API
       • Implémentation de codes de sortie appropriés (0 pour succès, 1 pour erreurs) pour les scénarios d'automatisation
       • Ajout d'un rapport de résumé détaillé avec comptages d'opérations réussies/échouées/ignorées
       • Validation de paramètres améliorée avec de meilleurs messages d'erreur et vérifications d'existence de fichiers
       • Amélioration de la capture de réponse d'erreur API pour un meilleur débogage
       • Ajout de récupération d'erreur gracieuse pour continuer le traitement lors d'échecs de lignes individuelles
v1.4 - Changement majeur pour la clarté des paramètres :
       • Renommage du paramètre -subscriptionId en -arcServerSubscriptionId pour une meilleure clarté
       • Mise à jour de toutes les références internes et de la documentation pour utiliser le nouveau nom de paramètre
       • Ajout d'un alias de rétrocompatibilité 'subscriptionId' pour maintenir la compatibilité avec les scripts existants
       • Mise à jour de tous les exemples dans la documentation pour refléter le nouveau nom de paramètre


.LINK
Pour obtenir plus d'informations sur l'API REST des licences ESU Azure ARC, veuillez visiter :
https://learn.microsoft.com/en-us/azure/azure-arc/servers/api-extended-security-updates

.EXAMPLE-1
./ManageESUAssignmentsFR -arcServerSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "votre_valeur_secrète_application" `
-location "EastUS" `
-csvFilePath "C:\Temp\Fichier Association ESU.csv"

.EXAMPLE-2
./ManageESUAssignmentsFR -arcServerSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-licenseSubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "votre_valeur_secrète_application" `
-location "EastUS" `
-csvFilePath "C:\Temp\Fichier Association ESU.csv"

.EXAMPLE-3
$authToken = Get-AzAccessToken -ResourceUrl https://management.azure.com/
./ManageESUAssignmentsFR -arcServerSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-location "EastUS" `
-csvFilePath "C:\Temp\Fichier Association ESU.csv" `
-userToken $authToken

.EXAMPLE-4
./ManageESUAssignmentsFR -arcServerSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-tenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-appID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
-clientSecret "votre_valeur_secrète_application" `
-location "EastUS" `
-csvFilePath "C:\Temp\Fichier Association ESU.csv" `
-DryRun

Ces exemples vont affecter ou désaffecter (délier) des licences ESU aux/des objets serveur ARC basés sur les informations fournies dans le fichier CSV.
L'exemple 2 montre comment spécifier un abonnement différent pour les licences ESU.
L'exemple 3 montre comment utiliser l'authentification par jeton Microsoft Entra ID au lieu des informations d'identification du principal de service.
L'exemple 4 montre comment effectuer une simulation pour tester le script sans apporter de modifications réelles.

Vous devrez fournir les informations suivantes dans le fichier CSV :
LicenseName: Le nom de la licence ESU à utiliser.
licenseResourceGroupName: Le nom du groupe de ressources où se trouve l'objet licence ESU.
ServerResourceGroupName: Le nom du groupe de ressources où se trouve l'objet serveur ARC.
Name (ou ARCServerName): Le nom de l'objet serveur ARC.
AssignESULicense: TRUE ou FALSE selon que vous souhaitez affecter ou délier la licence de l'objet serveur ARC.
LicenseSubscriptionId (Optionnel): L'ID d'abonnement où se trouve la licence. Cette colonne a toujours la priorité sur les paramètres de ligne de commande. Si non fournie, utilise le paramètre du script ou par défaut l'abonnement du serveur ARC.

DÉPANNAGE DES ERREURS 403 FORBIDDEN :
Si vous recevez des erreurs 403 Forbidden, vérifiez les points suivants :

1. Permissions du Principal de Service (Abonnement Serveur ARC) :
   - Attribuez le rôle 'Azure Connected Machine Resource Administrator' au niveau de l'abonnement ou du groupe de ressources
   - Ou attribuez le rôle 'Contributor' au niveau de l'abonnement ou du groupe de ressources
   
2. Permissions du Principal de Service (Abonnement Licence, si différent) :
   - Attribuez le rôle 'Contributor' au niveau de l'abonnement ou du groupe de ressources où se trouvent les licences ESU
   
3. Existence des Ressources :
   - Vérifiez que le serveur ARC existe : az connectedmachine show --name "NomServeur" --resource-group "NomRG" --subscription "IDSub"
   - Vérifiez que la licence ESU existe : az rest --method GET --url "https://management.azure.com/subscriptions/IDSUB/resourceGroups/NOMRG/providers/Microsoft.HybridCompute/licenses/NOMLICENCE?api-version=2023-06-20-preview"
   
4. Accès Inter-Abonnements :
   - Lorsque la licence et le serveur ARC sont dans des abonnements différents, assurez-vous que le principal de service a les rôles appropriés dans LES DEUX abonnements
   
5. Noms des Ressources :
   - Assurez-vous que les noms de ressources dans le CSV correspondent exactement (sensible à la casse)
   - Vérifiez les espaces supplémentaires ou les caractères spéciaux dans les données CSV

#>

##############################
#Bloc de définition des paramètres #
##############################

param(
    [Parameter(Mandatory=$true, HelpMessage="L'ID de l'abonnement où se trouvent les serveurs ARC.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="L'entrée '{0}' doit être un ID d'abonnement valide.")]
    [Alias("sub", "subscriptionId")]
    [string]$arcServerSubscriptionId,

    [Parameter(Mandatory=$false, HelpMessage="L'ID de l'abonnement où se trouvent les licences ESU. Si non fourni, utilisera le même abonnement que les serveurs ARC.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="L'entrée '{0}' doit être un ID d'abonnement valide.")]
    [Alias("licenseSub")]
    [string]$licenseSubscriptionId,

    [Parameter(Mandatory=$false, HelpMessage="L'ID de locataire de l'instance Microsoft Entra utilisée pour l'authentification.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="L'entrée '{0}' doit être un ID de locataire valide.")]
    [string]$tenantId,

    [Parameter(Mandatory=$false, HelpMessage="L'ID d'application (client) tel qu'affiché sous Inscriptions d'applications qui sera utilisé pour s'authentifier à l'API Azure.")]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', ErrorMessage="L'entrée '{0}' doit être un ID d'application valide.")]
    [string]$appID,

    [Parameter(Mandatory=$false, HelpMessage="Un secret client valide (non expiré) pour l'inscription d'application qui sera utilisé pour s'authentifier à l'API Azure.")]
    [Alias("s","secret","sec")]
    [string]$clientSecret,

    [Parameter(Mandatory=$true, HelpMessage="La région où la licence sera créée.")]
    [ValidateNotNullOrEmpty()]
    [Alias("l")]
    [string]$location,

    [Parameter (Mandatory=$true, HelpMessage="Le chemin complet vers le fichier CSV contenant la liste des ressources éligibles ESU.")]
    [ValidateScript({
        if (-not (Test-Path $_ -PathType Leaf)) {
            throw "Le fichier CSV n'existe pas : $_"
        }
        if (-not ($_ -match '\.csv$')) {
            throw "Le fichier doit avoir l'extension .csv : $_"
        }
        return $true
    })]
    [Alias("csv")]
    [string] $csvFilePath,

    [Parameter(Mandatory=$false, HelpMessage="Le nom du fichier de journal à créer.")]
    [Alias("log")]
    [string]$logFileName,

    [Parameter(Mandatory=$false, HelpMessage="Le jeton bearer obtenu de l'API Azure par l'utilisateur. Si non fourni, le script nécessitera les paramètres appID, clientSecret et tenantId.")]
    [Alias("token")]
    [System.Object]$userToken,

    [Parameter(Mandatory=$false, HelpMessage="Effectuer une simulation sans apporter de modifications réelles. Montre ce qui serait fait.")]
    [Alias("whatif")]
    [switch]$DryRun
)

#####################################
#Fin du bloc de définition des paramètres #
#####################################



##############################
# Bloc de définition des variables #
##############################

# NE PAS modifier ces variables car cela pourrait casser le script. Elles sont destinées à être statiques.
$global:creator = $MyInvocation.MyCommand.Name

# Constantes de configuration
$script:CONFIG = @{
    ApiVersion = "2023-06-20-preview"
    AzureResourceUrl = "https://management.azure.com/"
    LoginEndpoint = "https://login.microsoftonline.com"
    MaxRetryAttempts = 3
    RetryDelaySeconds = 5
    RequiredCSVColumns = @('LicenseName', 'licenseResourceGroupName', 'ServerResourceGroupName', 'Name', 'AssignESULicense')
}

#########################################
# Fin du bloc de définition des variables #
#########################################



################################
# Bloc de définition des fonctions #
################################

function AssignESULicense {

    param (
        [string]$appID,
        [string]$clientSecret,
        [string]$tenantId,
        [string]$arcServerSubscriptionId,
        [string]$licenseSubscriptionId,
        [string]$licenseResourceGroupName,
        [string]$licenseName,
        [string]$ARCServerName,
        [string]$serverResourceGroupName,
        [string]$location,
        [string]$token,
        [switch]$unassign,
        [switch]$dryRun
    )

    try {
        # Valider les paramètres requis
        if ([string]::IsNullOrWhiteSpace($arcServerSubscriptionId)) { throw "arcServerSubscriptionId est requis" }
        if ([string]::IsNullOrWhiteSpace($licenseSubscriptionId)) { throw "licenseSubscriptionId est requis" }
        if ([string]::IsNullOrWhiteSpace($licenseResourceGroupName)) { throw "licenseResourceGroupName est requis" }
        if ([string]::IsNullOrWhiteSpace($licenseName)) { throw "licenseName est requis" }
        if ([string]::IsNullOrWhiteSpace($ARCServerName)) { throw "ARCServerName est requis" }
        if ([string]::IsNullOrWhiteSpace($serverResourceGroupName)) { throw "serverResourceGroupName est requis" }
        if ([string]::IsNullOrWhiteSpace($location)) { throw "location est requis" }

        $apiEndpoint = "https://management.azure.com/subscriptions/$arcServerSubscriptionId/resourceGroups/$serverResourceGroupName/providers/Microsoft.HybridCompute/machines/$ARCServerName/licenseProfiles/default?api-version=$($script:CONFIG.ApiVersion)"
        $licenseID = "/subscriptions/$licenseSubscriptionId/resourceGroups/$licenseResourceGroupName/providers/Microsoft.HybridCompute/licenses/$licenseName" 
        $method = "PUT"

        # Utilise le jeton fourni ou obtient un jeton bearer de l'application
        if ($token) {
            $bearerToken = $token
        } else {
            $bearerToken = Get-AzureADBearerToken -appID $appID -clientSecret $clientSecret -tenantId $tenantId 
            if ([string]::IsNullOrWhiteSpace($bearerToken)) {
                throw "Échec de l'obtention du jeton d'authentification"
            }
        }

        # Définit les en-têtes pour la requête
        $headers = @{
            "Authorization" = "Bearer $bearerToken"
            "Content-Type" = "application/json"
        }

        # Crée le corps de la requête selon le type d'action (affecter ou désaffecter)
        if ($unassign) {
            $requestBody = @{
                location = $location
                properties = @{
                    esuProfile = @{
                        
                    }
                }
            }
        } 
        else {
            $requestBody = @{
                location = $location
                properties = @{
                    esuProfile = @{
                        "assignedLicense" = $licenseID 
                    }
                }
            }  
        }

        # Convertit le corps de la requête en JSON
        $requestBodyJson = $requestBody | ConvertTo-Json -Depth 5

        # Valide l'accès aux ressources avant de tenter l'opération
        Write-Logfile "Validation de l'accès au serveur ARC '$ARCServerName'..." "INFO"
        $arcServerAccess = Test-AzureResourceAccess -subscriptionId $arcServerSubscriptionId -resourceGroupName $serverResourceGroupName -resourceName $ARCServerName -resourceType "Microsoft.HybridCompute/machines" -bearerToken $bearerToken
        
        Write-Logfile "Validation de l'accès à la licence ESU '$licenseName'..." "INFO"
        $licenseAccess = Test-AzureResourceAccess -subscriptionId $licenseSubscriptionId -resourceGroupName $licenseResourceGroupName -resourceName $licenseName -resourceType "Microsoft.HybridCompute/licenses" -bearerToken $bearerToken
        
        if (-not $arcServerAccess) {
            throw "Impossible d'accéder au serveur ARC '$ARCServerName' dans le groupe de ressources '$serverResourceGroupName'. Vérifiez les permissions et l'existence de la ressource."
        }
        
        if (-not $licenseAccess) {
            throw "Impossible d'accéder à la licence ESU '$licenseName' dans le groupe de ressources '$licenseResourceGroupName'. Vérifiez les permissions et l'existence de la ressource."
        }

        # Gère le mode simulation
        if ($dryRun) {
            $action = if ($unassign) { "délier" } else { "affecter" }
            Write-Logfile "[SIMULATION] $action la licence ESU '$licenseName' au/du serveur '$ARCServerName'" "INFO"
            Write-Logfile "[SIMULATION] Point de terminaison API : $apiEndpoint" "INFO"
            Write-Logfile "[SIMULATION] Corps de la requête : $requestBodyJson" "INFO"
            Write-Logfile "[SIMULATION] Validation des ressources réussie pour le serveur ARC et la licence ESU" "SUCCESS"
            return $true
        }

        # Envoie la requête PUT pour mettre à jour la licence
        try {
            Invoke-RestMethod -Uri $apiEndpoint -Method $method -Headers $headers -Body $requestBodyJson | Out-Null
            
            $action = if ($unassign) { "déliée" } else { "affectée" }
            Write-Logfile "Licence ESU '$licenseName' $action avec succès au/du serveur '$ARCServerName'" "SUCCESS"
            return $true
        } catch {
            throw $_
        }
        
    } catch {
        $action = if ($unassign) { "délier" } else { "affecter" }
        $errorMessage = "Échec de $action la licence ESU '$licenseName' au/du serveur '$ARCServerName' : $($_.Exception.Message)"
        Write-Logfile $errorMessage "ERROR"
        
        # Journalise des détails supplémentaires pour le débogage
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode
            Write-Logfile "Code de statut HTTP : $statusCode" "ERROR"
            
            try {
                $errorDetails = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($errorDetails)
                $responseBody = $reader.ReadToEnd()
                Write-Logfile "Détails d'erreur API : $responseBody" "ERROR"
            } catch {
                Write-Logfile "Impossible de lire les détails de la réponse d'erreur" "WARNING"
            }
            
            # Fournit des conseils spécifiques pour les erreurs 403
            if ($statusCode -eq 403) {
                Write-Logfile "Erreur 403 Forbidden - Causes possibles :" "ERROR"
                Write-Logfile "1. Le principal de service manque du rôle 'Azure Connected Machine Resource Administrator' sur l'abonnement serveur ARC" "ERROR"
                Write-Logfile "2. Le principal de service manque du rôle 'Contributor' ou 'Owner' sur l'abonnement licence" "ERROR"
                Write-Logfile "3. La ressource serveur ARC '$ARCServerName' n'existe pas dans le groupe de ressources '$serverResourceGroupName'" "ERROR"
                Write-Logfile "4. La ressource licence '$licenseName' n'existe pas dans le groupe de ressources '$licenseResourceGroupName'" "ERROR"
                Write-Logfile "5. Permissions inter-abonnements pas correctement configurées" "ERROR"
            }
        }
        return $false
    }
}

function Test-ServicePrincipalPermissions {
    param(
        [string]$subscriptionId,
        [string]$bearerToken
    )
    
    Write-Logfile "Vérification des permissions du principal de service sur l'abonnement '$subscriptionId'..." "INFO"
    
    $headers = @{
        "Authorization" = "Bearer $bearerToken"
        "Content-Type" = "application/json"
    }
    
    # Essaie de lister les affectations de rôles pour valider les permissions
    $roleAssignmentsUri = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()"
    
    try {
        Invoke-RestMethod -Uri $roleAssignmentsUri -Method GET -Headers $headers | Out-Null
        Write-Logfile "Le principal de service a des permissions suffisantes pour lire les affectations de rôles" "SUCCESS"
        return $true
    } catch {
        $statusCode = $_.Exception.Response.StatusCode
        Write-Logfile "Impossible de lire les affectations de rôles sur l'abonnement : HTTP $statusCode" "WARNING"
        
        if ($statusCode -eq 403) {
            Write-Logfile "Le principal de service peut manquer du rôle 'Reader' au niveau de l'abonnement" "WARNING"
        }
        return $false
    }
}

function Test-AzureResourceAccess {
    param(
        [string]$subscriptionId,
        [string]$resourceGroupName,
        [string]$resourceName,
        [string]$resourceType,
        [string]$bearerToken
    )
    
    $headers = @{
        "Authorization" = "Bearer $bearerToken"
        "Content-Type" = "application/json"
    }
    
    $resourceUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/$resourceType/$resourceName"
    
    try {
        Invoke-RestMethod -Uri "$resourceUri`?api-version=2022-11-01" -Method GET -Headers $headers | Out-Null
        return $true
    } catch {
        $statusCode = $_.Exception.Response.StatusCode
        Write-Logfile "Impossible d'accéder à $resourceType '$resourceName' dans RG '$resourceGroupName' : HTTP $statusCode" "WARNING"
        return $false
    }
}

function Test-CSVRowData {
    param(
        [PSCustomObject]$row,
        [int]$rowNumber
    )
    
    $isValid = $true
    $errors = @()
    
    # Vérifie les champs requis
    $requiredFields = @{
        'LicenseName' = $row.LicenseName
        'licenseResourceGroupName' = $row.licenseResourceGroupName
        'ServerResourceGroupName' = $row.ServerResourceGroupName
        'Name' = $row.Name
        'AssignESULicense' = $row.AssignESULicense
    }
    
    foreach ($field in $requiredFields.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace($field.Value)) {
            $errors += "Champ requis manquant ou vide : $($field.Key)"
            $isValid = $false
        }
    }
    
    # Valide les valeurs AssignESULicense
    if ($row.AssignESULicense -notin @('True', 'False', 'true', 'false', 'TRUE', 'FALSE')) {
        $errors += "AssignESULicense doit être 'True' ou 'False', reçu : '$($row.AssignESULicense)'"
        $isValid = $false
    }
    
    # Valide le format de l'ID d'abonnement s'il est fourni
    if ($row.PSObject.Properties['LicenseSubscriptionId'] -and 
        ![string]::IsNullOrWhiteSpace($row.LicenseSubscriptionId) -and
        $row.LicenseSubscriptionId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        $errors += "Format LicenseSubscriptionId invalide : '$($row.LicenseSubscriptionId)'"
        $isValid = $false
    }
    
    if (-not $isValid) {
        Write-Logfile "Erreurs de validation ligne $rowNumber : $($errors -join '; ')" "ERROR"
    }
    
    return $isValid
}

function Get-AzureADBearerToken {
    param(
        [string]$appID,
        [string]$clientSecret,
        [string]$tenantId,
        [int]$retryCount = 3,
        [int]$retryDelaySeconds = 5
    )

    # Définit le point de terminaison d'autorisation de jeton
    $oAuthEndpoint = "$($script:CONFIG.LoginEndpoint)/$tenantId/oauth2/token"

    # Construit le corps de la requête
    $authbody = @{
        grant_type = "client_credentials"
        client_id = $appID
        client_secret = $clientSecret
        resource = $script:CONFIG.AzureResourceUrl
    }
    
    # Obtient le jeton avec logique de nouvelle tentative
    Write-Verbose "Authentification..."
    
    for ($attempt = 1; $attempt -le $script:CONFIG.MaxRetryAttempts; $attempt++) {
        try { 
            $response = Invoke-WebRequest -Method Post -Uri $oAuthEndpoint -ContentType "application/x-www-form-urlencoded" -Body $authbody
            $accessToken = ($response.Content | ConvertFrom-Json).access_token
            
            if ([string]::IsNullOrWhiteSpace($accessToken)) {
                throw "La réponse d'authentification ne contenait pas de jeton d'accès valide"
            }
            
            Write-Verbose "Authentification réussie"
            return $accessToken
        }
        catch { 
            $errorMessage = "Tentative d'authentification $attempt échouée : $($_.Exception.Message)"
            Write-Logfile $errorMessage "WARNING"
            
            if ($attempt -eq $script:CONFIG.MaxRetryAttempts) {
                Write-Logfile "Toutes les tentatives d'authentification ont échoué. Arrêt." "ERROR"
                return $null
            } else {
                Write-Logfile "Nouvelle tentative dans $($script:CONFIG.RetryDelaySeconds) secondes..." "INFO"
                Start-Sleep -Seconds $script:CONFIG.RetryDelaySeconds
            }
        }    
    }
    
    return $null
}

function Write-Logfile  {
    param(
    [Parameter (Mandatory=$true)]
    [Alias("m")]
    [string] $message,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
    [string] $level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$level] $message"
    
    # Sortie vers la console avec les couleurs appropriées
    switch ($level) {
        "ERROR" { Write-Host $logMessage -ForegroundColor Red }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logMessage -ForegroundColor Green }
        default { Write-Host $logMessage }
    }
    
    # Écrit aussi dans la transcription si active
    Write-Output $logMessage
}

#######################################
# Fin du bloc de définition des fonctions #
#######################################



#####################
# Bloc de script principal #
#####################

Clear-Host
# Obtient un jeton d'autorisation soit de celui fourni par l'utilisateur ou de l'inscription d'application Azure si un a été fourni dans la ligne de commande.

# Vérifie si le jeton est encore valide
if ($userToken) {
    if ($userToken.ExpiresOn -gt (Get-Date)) {
        Write-Host "Utilisation du jeton d'authentification Microsoft Entra ID fourni" -ForegroundColor Green
        #$token = $userToken.Token
        #Variable $token modifiée pour correspondre au nouveau format de sortie de Get-AzAccessToken car elle a changé d'une chaîne à un type SecureString
        $token = ConvertFrom-SecureString -SecureString $userToken.Token -AsPlainText
    } else {
        Write-Host "Le jeton utilisateur fourni a expiré. Veuillez fournir un jeton valide.`nArrêt." -ForegroundColor Red
        exit
    }
} elseif ($tenantId -and $appID -and $clientSecret) {
    Write-Host "Obtention du jeton d'authentification de Microsoft Entra ID" -ForegroundColor Green
    $token = Get-AzureADBearerToken -appID $appID -clientSecret $clientSecret -tenantId $tenantId 
} else {
    Write-Host "Vous devez fournir soit les paramètres tenant, appID et clientSecrets ou un objet jeton d'authentification valide.`nArrêt." -ForegroundColor Red
    exit
}

Write-Host ""
Write-Host "=============================================="
if ($DryRun) {
    Write-Host "MODE SIMULATION - Aucune modification réelle ne sera apportée"
    Write-Host "=============================================="
}
Write-Host "Démarrage des affectations de licences ESU depuis le fichier CSV"
Write-Host "=============================================="

If (![string]::IsNullOrWhiteSpace($logFileName)) {Start-Transcript -Path $logFileName}

# Valide le fichier CSV et importe les données
try {
    $data = Import-Csv -Path $csvFilePath
    if ($data.Count -eq 0) {
        Write-Logfile "Le fichier CSV est vide ou n'a pas de lignes de données" "ERROR"
        exit 1
    }
    Write-Logfile "$($data.Count) lignes importées avec succès depuis le fichier CSV" "INFO"
} catch {
    Write-Logfile "Échec de l'importation du fichier CSV : $($_.Exception.Message)" "ERROR"
    exit 1
}

# Valide les colonnes CSV requises
$missingColumns = $script:CONFIG.RequiredCSVColumns | Where-Object { $_ -notin $data[0].PSObject.Properties.Name }
if ($missingColumns) {
    Write-Logfile "Colonnes CSV requises manquantes : $($missingColumns -join ', ')" "ERROR"
    exit 1
}

# Initialise les compteurs pour le résumé
$successCount = 0
$errorCount = 0
$skipCount = 0

# Traite chaque ligne avec suivi de progression
$totalRows = $data.Count
$currentRow = 0

foreach ($row in $data) {
    $currentRow++
    $percentComplete = [math]::Round(($currentRow / $totalRows) * 100, 1)
    Write-Progress -Activity "Traitement des affectations de licences ESU" -Status "Traitement ligne $currentRow sur $totalRows ($percentComplete%)" -PercentComplete $percentComplete
    
    # Valide les données de la ligne
    if (-not (Test-CSVRowData -row $row -rowNumber $currentRow)) {
        $skipCount++
        continue
    }
         
        # Détermine quel abonnement utiliser pour la licence
        # Priorité : 1) Colonne CSV LicenseSubscriptionId (a toujours la priorité), 2) Paramètre de script, 3) Abonnement serveur ARC (rétrocompatibilité)
        
        if ($row.PSObject.Properties['LicenseSubscriptionId'] -and ![string]::IsNullOrWhiteSpace($row.LicenseSubscriptionId)) {
            # La colonne CSV a toujours la priorité si fournie
            $currentLicenseSubscriptionId = $row.LicenseSubscriptionId
            Write-Verbose "Utilisation de l'abonnement licence du CSV : $currentLicenseSubscriptionId"
        }
        elseif (![string]::IsNullOrWhiteSpace($licenseSubscriptionId)) {
            # Utilise le paramètre de ligne de commande si pas de valeur CSV
            $currentLicenseSubscriptionId = $licenseSubscriptionId
            Write-Verbose "Utilisation de l'abonnement licence du paramètre : $currentLicenseSubscriptionId"
        }
        else {
            # Revient à l'abonnement serveur ARC pour la rétrocompatibilité
            $currentLicenseSubscriptionId = $arcServerSubscriptionId
            Write-Verbose "Utilisation de l'abonnement serveur ARC pour la licence : $currentLicenseSubscriptionId"
        }

        # Affecte la licence au serveur si demandé depuis le fichier CSV (la colonne AssignESULicense doit dire TRUE pour affectation ou FALSE pour déliaison)
        switch ($row.AssignESULicense) {
            "True" {
                Write-Logfile "Affectation de la licence ESU ($($row.LicenseName)) au serveur ($($row.name)) [Abonnement Licence : $currentLicenseSubscriptionId]" "INFO"
                
                $params = @{
                    'arcServerSubscriptionId' = $arcServerSubscriptionId
                    'licenseSubscriptionId' = $currentLicenseSubscriptionId
                    'tenantId' = $tenantId
                    'appID' = $appID
                    'clientSecret' = $clientSecret
                    'token' = $token
                    'licenseResourceGroupName' = $row.licenseResourceGroupName
                    'licenseName' = $row.LicenseName
                    'serverResourceGroupName' = $row.ServerResourceGroupName
                    'ARCServerName' = $row.Name
                    'location' = $location
                    'dryRun' = $DryRun
                }
                
                $result = AssignESULicense @params
                if ($result) { $successCount++ } else { $errorCount++ }
              }

            "False" {
                Write-Logfile "Déliaison de la licence ESU ($($row.LicenseName)) du serveur ($($row.name)) [Abonnement Licence : $currentLicenseSubscriptionId]" "INFO"

                $params = @{
                    'arcServerSubscriptionId' = $arcServerSubscriptionId
                    'licenseSubscriptionId' = $currentLicenseSubscriptionId
                    'tenantId' = $tenantId
                    'appID' = $appID
                    'clientSecret' = $clientSecret
                    'token' = $token
                    'licenseResourceGroupName' = $row.licenseResourceGroupName
                    'licenseName' = $row.LicenseName
                    'serverResourceGroupName' = $row.ServerResourceGroupName
                    'ARCServerName' = $row.Name
                    'location' = $location
                    'unassign' = $true
                    'dryRun' = $DryRun
                }

                $result = AssignESULicense @params
                if ($result) { $successCount++ } else { $errorCount++ }
              }

            Default {
                Write-Logfile "Action d'affectation de licence manquante ou invalide pour le serveur '$($row.name)' et la licence '$($row.LicenseName)'. 'True' ou 'False' attendu, reçu '$($row.AssignESULicense)'" "WARNING"
                $skipCount++
            }
        }

    }   

# Termine le suivi de progression
Write-Progress -Activity "Traitement des affectations de licences ESU" -Completed

# Affiche le résumé
Write-Host ""
Write-Host "=============================================="
if ($DryRun) {
    Write-Host "SIMULATION - Résumé des affectations de licences ESU"
} else {
    Write-Host "Résumé des affectations de licences ESU"
}
Write-Host "=============================================="
Write-Logfile "Total de lignes traitées : $totalRows" "INFO"
Write-Logfile "Opérations réussies : $successCount" "SUCCESS"
Write-Logfile "Opérations échouées : $errorCount" $(if ($errorCount -gt 0) { "ERROR" } else { "INFO" })
Write-Logfile "Opérations ignorées : $skipCount" $(if ($skipCount -gt 0) { "WARNING" } else { "INFO" })

if ($DryRun) {
    Write-Logfile "Simulation terminée avec succès. Aucune modification réelle n'a été apportée." "INFO"
    $exitCode = 0
} elseif ($errorCount -gt 0) {
    Write-Logfile "Script terminé avec des erreurs. Veuillez consulter le journal pour les détails." "WARNING"
    $exitCode = 1
} else {
    Write-Logfile "Script terminé avec succès." "SUCCESS"
    $exitCode = 0
}
    
If (![string]::IsNullOrWhiteSpace($logFileName)) {Stop-Transcript}

exit $exitCode



############################
# Fin du bloc de script principal #
############################