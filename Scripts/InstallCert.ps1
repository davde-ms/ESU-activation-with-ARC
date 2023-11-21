# Define the path to the certificate
$certPath = "C:\path\to\cert.crt"

# Import the certificate
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $certPath

# Define the certificate store
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store "CA","LocalMachine"

# Open the store
$store.Open("ReadWrite")

# Add the certificate
$store.Add($cert)

# Close the store
$store.Close()