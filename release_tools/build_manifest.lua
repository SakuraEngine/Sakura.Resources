import("core.base.json")
function main(package_path, manifest_path)
    printf("package_path: %s, manifest_path: %s\n", package_path, manifest_path)

    local packages = os.files(path.join(os.curdir(), package_path))
    local manifest = {}
    for _, package in ipairs(packages) do
        package_name = path.filename(package)
        
        if package_name != path.filename(manifest_path) then
            package_sha = hash.sha256(package)
            printf("package: %s, sha256: %s\n", package_name, package_sha)
            manifest[package_name] = package_sha
        end
    end
    json.savefile(path.join(os.curdir(), manifest_path), manifest)
end