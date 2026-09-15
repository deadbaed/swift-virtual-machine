# Download IPSW file

To create a virtual machine, the IPSW corresponding to the Mac hardware and macOS version is required.

## Find Mac model name

Use this command to report the model name of your mac:

```shell
sysctl -n hw.model
```

## Download list of supported macOS versions

Requires `jq`, can be provided with `nix-shell -p curl jq`.

```shell
MY_MAC_MODEL=$(sysctl -n hw.model)
MY_MAC_MODEL_FOR_URL=$(printf %s $MY_MAC_MODEL | jq -sRr @uri)
curl https://api.ipsw.me/v4/ipsw/device/$MY_MAC_MODEL_FOR_URL | jq > $MY_MAC_MODEL.json
```

## Download IPSW

Once you have the URL to your desired IPSW, simply download it with `wget` (useful to resume the download when your network is bad):

```shell
wget -c https://updates.cdn-apple.com/xxxxxxxxxx
```

Afterwards, compute the checksum of the downloaded file:

```shell
/usr/bin/shasum -a 256 ./downloaded-file.ipsw
```

And compare to the checksum inside the JSON file.
