import("core.base.json")
function main(package_path, manifest_path)
    printf("===== [package_path]: %s\n", package_path)
    printf("===== [manifest_path]: %s\n", manifest_path)

    -- get packages
    local packages = os.files(path.join(os.curdir(), package_path))
    local manifest = {}

    -- load old manifest if exists
    local old_manifest = {}
    if os.isfile(manifest_path) then
        old_manifest = json.loadfile(manifest_path)
    end

    for _, package in ipairs(packages) do
        package_name = path.filename(package)
        
        if package_name ~= path.filename(manifest_path) then
            package_sha = hash.sha256(package)
            manifest[package_name] = package_sha

            old_package_sha = old_manifest[package_name]

            if old_package_sha and old_package_sha ~= package_sha then
                printf("[KEEP] package: %s, sha256: %s\n", package_name, package_sha)
            else
                printf("[CHANGED] package: %s, sha256: %s, old_sha256: %s\n", package_name, package_sha, old_package_sha)
            end
        end
    end
    json.savefile(path.join(os.curdir(), manifest_path), manifest)
end