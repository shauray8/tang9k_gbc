export OSS_CAD_SUITE="${OSS_CAD_SUITE:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/tools/oss-cad-suite}"
export PATH="$OSS_CAD_SUITE/bin:$PATH"
