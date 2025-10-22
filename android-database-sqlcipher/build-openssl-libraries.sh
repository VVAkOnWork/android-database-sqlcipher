#! /usr/bin/env bash

MINIMUM_ANDROID_SDK_VERSION=$1
MINIMUM_ANDROID_64_BIT_SDK_VERSION=$2
OPENSSL=openssl-$3

(cd src/main/external/;
 gunzip -c ${OPENSSL}.tar.gz | tar xf -
)

(cd src/main/external/${OPENSSL};

 if [[ ! ${MINIMUM_ANDROID_SDK_VERSION} ]]; then
     echo "MINIMUM_ANDROID_SDK_VERSION was not provided, include and rerun"
     exit 1
 fi

 if [[ ! ${MINIMUM_ANDROID_64_BIT_SDK_VERSION} ]]; then
     echo "MINIMUM_ANDROID_64_BIT_SDK_VERSION was not provided, include and rerun"
     exit 1
 fi

 if [[ ! ${ANDROID_NDK_HOME} ]]; then
     echo "ANDROID_NDK_HOME environment variable not set, set and rerun"
     exit 1
 fi

 HOST_INFO=`uname -a`
 case ${HOST_INFO} in
     Darwin*)
         TOOLCHAIN_SYSTEM=darwin-x86_64
         ;;
     Linux*)
         if [[ "${HOST_INFO}" == *i686* ]]
         then
             TOOLCHAIN_SYSTEM=linux-x86
         else
             TOOLCHAIN_SYSTEM=linux-x86_64
         fi
         ;;
     *)
         echo "Toolchain unknown for host system"
         exit 1
         ;;
 esac

 NDK_TOOLCHAIN_VERSION=4.9
 ANDROID_LIB_ROOT=../android-libs
 OPENSSL_CONFIGURE_OPTIONS="-fPIC -fstack-protector-all no-idea no-camellia \
 no-seed no-bf no-cast no-rc2 no-rc4 no-rc5 no-md2 \
 no-md4 no-ecdh no-sock no-ssl3 \
 no-dsa no-dh no-ec no-ecdsa no-tls1 \
 no-rfc3779 no-whirlpool no-srp \
 no-mdc2 no-ecdh no-engine \
 no-srtp"

 rm -rf ${ANDROID_LIB_ROOT}
 
 for SQLCIPHER_TARGET_PLATFORM in armeabi-v7a x86 x86_64 arm64-v8a
 do
     echo "Building libcrypto.a for ${SQLCIPHER_TARGET_PLATFORM}"
     case "${SQLCIPHER_TARGET_PLATFORM}" in
         armeabi-v7a)
             CONFIGURE_ARCH="android-arm -march=armv7-a"
             ANDROID_API_VERSION=${MINIMUM_ANDROID_SDK_VERSION}
             OFFSET_BITS=32
             # 设置 ARM 工具链
             TOOLCHAIN_PREFIX=armv7a-linux-androideabi
             BINUTILS_PREFIX=arm-linux-androideabi
             ;;
         x86)
             CONFIGURE_ARCH=android-x86
             ANDROID_API_VERSION=${MINIMUM_ANDROID_SDK_VERSION}
             OFFSET_BITS=32
             # 设置 x86 工具链
             TOOLCHAIN_PREFIX=i686-linux-android
             BINUTILS_PREFIX=i686-linux-android
             ;;
         x86_64)
             CONFIGURE_ARCH=android64-x86_64
             ANDROID_API_VERSION=${MINIMUM_ANDROID_64_BIT_SDK_VERSION}
             OFFSET_BITS=64
             # 设置 x86_64 工具链
             TOOLCHAIN_PREFIX=x86_64-linux-android
             BINUTILS_PREFIX=x86_64-linux-android
             ;;
         arm64-v8a)
             CONFIGURE_ARCH=android-arm64
             ANDROID_API_VERSION=${MINIMUM_ANDROID_64_BIT_SDK_VERSION}
             OFFSET_BITS=64
             # 设置 arm64 工具链
             TOOLCHAIN_PREFIX=aarch64-linux-android
             BINUTILS_PREFIX=aarch64-linux-android
             ;;
         *)
             echo "Unsupported build platform:${SQLCIPHER_TARGET_PLATFORM}"
             exit 1
     esac

     TOOLCHAIN_BIN_PATH=${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/${TOOLCHAIN_SYSTEM}/bin

     # 设置完整路径的工具链
     export CC=${TOOLCHAIN_BIN_PATH}/${TOOLCHAIN_PREFIX}${ANDROID_API_VERSION}-clang
     export CXX=${TOOLCHAIN_BIN_PATH}/${TOOLCHAIN_PREFIX}${ANDROID_API_VERSION}-clang++
     export AR=${TOOLCHAIN_BIN_PATH}/${BINUTILS_PREFIX}-ar
     export LD=${TOOLCHAIN_BIN_PATH}/${BINUTILS_PREFIX}-ld
     export RANLIB=${TOOLCHAIN_BIN_PATH}/${BINUTILS_PREFIX}-ranlib
     export STRIP=${TOOLCHAIN_BIN_PATH}/${BINUTILS_PREFIX}-strip

     # 验证工具是否存在
     if [[ ! -f ${CC} ]]; then
         echo "Error: Compiler not found: ${CC}"
         exit 1
     fi

     echo "Using compiler: ${CC}"
     echo "Using linker: ${LD}"

     # 清理之前的构建
     make distclean > /dev/null 2>&1 || true

     # 配置 OpenSSL
     ./Configure ${CONFIGURE_ARCH} \
                 -D__ANDROID_API__=${ANDROID_API_VERSION} \
                 -D_FILE_OFFSET_BITS=${OFFSET_BITS} \
                 ${OPENSSL_CONFIGURE_OPTIONS}

     if [[ $? -ne 0 ]]; then
         echo "Error executing:./Configure ${CONFIGURE_ARCH} ${OPENSSL_CONFIGURE_OPTIONS}"
         exit 1
     fi

     # 关键修复：修改 Makefile 以确保使用正确的工具链
     if [[ -f Makefile ]]; then
         echo "Patching Makefile for correct toolchain..."

         # 替换 CC
         sed -i.bak "s|^CC=.*|CC=${CC}|" Makefile

         # 替换 AR
         sed -i.bak "s|^AR=.*|AR=${AR}|" Makefile

         # 替换 RANLIB
         sed -i.bak "s|^RANLIB=.*|RANLIB=${RANLIB}|" Makefile

         # 确保链接器使用正确的命令 - 这是关键修复
         # 查找并替换所有可能调用系统ld的地方
         sed -i.bak "s|\\bld\\b|${LD}|g" Makefile
         sed -i.bak "s|/usr/bin/ld|${LD}|g" Makefile

         # 对于共享库链接，确保使用正确的编译器驱动链接而不是直接调用ld
         sed -i.bak "s|^SHARED_LDFLAGS=.*|SHARED_LDFLAGS= |" Makefile
     fi

     make clean

     # 方法1：直接使用make，依赖我们修补过的Makefile
     echo "Building with patched Makefile..."
     # 强制使用16KB页面对齐构建(在OpenSSL配置阶段就加入16KB对齐标志,在make命令中显式传递LDFLAGS)
     make build_libs CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" \
                     LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

     # 如果方法1失败，尝试方法2：明确传递所有工具
     if [[ $? -ne 0 ]]; then
         echo "Method 1 failed, trying method 2 with explicit toolchain..."
         make build_libs \
             CC="${CC}" \
             LD="${LD}" \
             AR="${AR}" \
             RANLIB="${RANLIB}" \
             NM="${TOOLCHAIN_BIN_PATH}/${BINUTILS_PREFIX}-nm" \
             STRIP="${STRIP}" \
             OBJDUMP="${TOOLCHAIN_BIN_PATH}/${BINUTILS_PREFIX}-objdump" \
             OBJCOPY="${TOOLCHAIN_BIN_PATH}/${BINUTILS_PREFIX}-objcopy"
     fi

     # 设置页面16KB大小对齐标志
     PAGE_16KB_ALIGN_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
     if [[ $? -ne 0 ]]; then
         echo "Error executing make for platform:${SQLCIPHER_TARGET_PLATFORM}"
         echo "Trying alternative approach: building static library only..."

         # 方法3：尝试只构建静态库，避免共享库链接问题
         make clean
         ./Configure ${CONFIGURE_ARCH} \
                     -D__ANDROID_API__=${ANDROID_API_VERSION} \
                     -D_FILE_OFFSET_BITS=${OFFSET_BITS} \
                     $PAGE_16KB_ALIGN_FLAGS \
                     no-shared ${OPENSSL_CONFIGURE_OPTIONS}

         # 再次修补Makefile
         sed -i.bak "s|^CC=.*|CC=${CC}|" Makefile
         sed -i.bak "s|^AR=.*|AR=${AR}|" Makefile
         sed -i.bak "s|^RANLIB=.*|RANLIB=${RANLIB}|" Makefile

         make build_libs
     fi

     if [[ $? -ne 0 ]]; then
         echo "Failed to build for platform:${SQLCIPHER_TARGET_PLATFORM}"
         exit 1
     fi

     # 验证生成的库对齐情况(添加对齐验证步骤)
     echo "Verifying alignment for ${SQLCIPHER_TARGET_PLATFORM}..."
     if [[ -f "libcrypto.a" ]]; then
         ${OBJDUMP} -p libcrypto.a | grep "Align" || true
         echo "libcrypto.a alignment check completed"
     fi

     mkdir -p ${ANDROID_LIB_ROOT}/${SQLCIPHER_TARGET_PLATFORM}
     if [[ -f libcrypto.a ]]; then
         mv libcrypto.a ${ANDROID_LIB_ROOT}/${SQLCIPHER_TARGET_PLATFORM}
         echo "Successfully built libcrypto.a for ${SQLCIPHER_TARGET_PLATFORM}"
     else
         echo "Error: libcrypto.a not found for ${SQLCIPHER_TARGET_PLATFORM}"
         # 检查是否有其他名称的库文件
         find . -name "*.a" -exec echo "Found library: {}" \;
         exit 1
     fi

     # 清理环境变量
     unset CC CXX AR LD RANLIB STRIP
 done
)

