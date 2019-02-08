#!/bin/sh

# run in yenten source directory
# ATTENTION: THIS WILL 'rm -rf dep build' IN THE CURRENT DIRECTORY

build_usage() {
	echo "$0 [linux/win] [32/64] [version]" >&1
	exit 1
}

build_have() {
	[ -f "$1" ] || return 1
	[ "$( sha256sum -b "$1" | cut -d' ' -f1 )" = "$2" ] || return 1
	return 0 
}

build_fetch() {
	if ! build_have "$ROOT/$1" "$2"; then
		curl -Lo "$ROOT/$1" "$3" || return 1
		if ! build_have "$ROOT/$1" "$2"; then
			echo "ERROR: checksum mismatch for $1" >&2
			return 1
		fi
	fi
	return 0
}

build_cleanup() {
	cd "$BASE" && rm -rf "$BUILD"
}

build_posix() {
	_CMP="$( which "$CROSS-$1" )"
	if [ -z "$_CMP" ]; then
		echo "ERROR: $1 not found"
		return 1
	fi
	if ! echo "$( readlink -f "$_CMP" )" | grep -q '.*-posix$'; then
		echo "ERROR: $1 is not set to posix (use 'update-alternatives --config $CROSS-$1)"
		return 1
	fi
	return 0
}

[ $# -lt 3 ] && build_usage
[ ! "$1" = linux ] && [ ! "$1" = win ] && build_usage
[ ! "$2" = 32 ] && [ ! "$2" = 64 ] && build_usage
[ -z "$3" ] && build_usage
OS="$1"
BITS="$2"
COIN=yenten
VERSION="$3"

if [ "$BITS" = 64 ]; then
	CROSS=x86_64-w64-mingw32
else
	CROSS=i686-w64-mingw32
fi
build_posix gcc || exit 1
build_posix g++ || exit 1

MAKE="make -j$( nproc )"
SELF="$( readlink -f "$0" )"
BASE="$( dirname "$SELF" )"
BUILD="${COIN}_${VERSION}_$OS$BITS.$( date | sha256sum | cut -d' ' -f1 )"
ROOT="$HOME/.builddep/$OS.$BITS"

mkdir -p "$ROOT/root" || exit 1
rm -rf dep || exit 1
mkdir dep || exit 1

if [ ! -f "$ROOT/have.db" ]; then
	build_fetch db-4.8.30.NC.tar.gz \
		12edc0df75bf9abd7f82f821795bcee50f42cb2e5f76a6a281b85732798364ef \
		http://download.oracle.com/berkeley-db/db-4.8.30.NC.tar.gz || \
		exit 1
	cd dep || exit 1
	tar xzf "$ROOT/db-4.8.30.NC.tar.gz" || exit 1
	cd db-4.8.30.NC/build_unix || exit 1
	../dist/configure "--prefix=$ROOT/root" --enable-cxx \
		--host=$CROSS --enable-mingw --disable-replication || exit 1
	$MAKE || exit 1
	$MAKE install_include install_lib || exit 1
	touch "$ROOT/have.db" || exit 1
	cd ../../.. || exit 1
fi

if [ ! -f "$ROOT/have.boost" ]; then
	build_fetch boost_1_65_1.tar.gz \
		a13de2c8fbad635e6ba9c8f8714a0e6b4264b60a29b964b940a22554705b6b60 \
		https://downloads.sourceforge.net/project/boost/boost/1.65.1/boost_1_65_1.tar.gz || \
		exit 1
	cd dep || exit 1
	tar xzf "$ROOT/boost_1_65_1.tar.gz" || exit 1
	cd boost_1_65_1 || exit 1
	tee tools/build/src/tools/mc.jam > /dev/null <<___
		import common ;
		import generators ;
		import feature : feature get-values ;
		import toolset : flags ;
		import type ;
		import rc ;
		feature.feature mc-compiler : $CROSS-windmc : propagated ;
		feature.set-default mc-compiler : $CROSS-windmc ;
		rule init ( )
		{
		}
		type.register MC : mc ;
		feature mc-input-encoding : ansi unicode : free ;
		feature mc-output-encoding : unicode ansi : free ;
		feature mc-set-customer-bit : no yes : free ;
		flags mc.compile MCFLAGS <mc-input-encoding>ansi : -a ;
		flags mc.compile MCFLAGS <mc-input-encoding>unicode : -u ;
		flags mc.compile MCFLAGS <mc-output-encoding>ansi : -A ;
		flags mc.compile MCFLAGS <mc-output-encoding>unicode : -U ;
		flags mc.compile MCFLAGS <mc-set-customer-bit>no : ;
		flags mc.compile MCFLAGS <mc-set-customer-bit>yes : -c ;
		generators.register-standard mc.compile.mc : MC : H RC : <mc-compiler>mc ;
		generators.register-standard mc.compile.$CROSS-windmc : MC : H RC : <mc-compiler>$CROSS-windmc ;
		actions compile.mc
		{
			mc \$(MCFLAGS) -h "\$(<[1]:DW)" -r "\$(<[2]:DW)" "\$(>:W)"
		}
		actions compile.$CROSS-windmc
		{
			windmc \$(MCFLAGS) -h "\$(<[1]:DW)" -r "\$(<[2]:DW)" "\$(>:W)"
		}
___
	[ $? = 0 ] || exit 1
	echo "using gcc : : $CROSS-g++ ;" | tee user-config.jam \
		> /dev/null || exit 1
	./bootstrap.sh --without-libraries=python "--prefix=$ROOT/root" || \
		exit 1
	TOOLSET=gcc-mingw
	FORMAT=pe
	TARGET=windows
	THREAD=win32
	./b2 -j$( nproc ) -q -d0 --user-config=user-config.jam \
		toolset=$TOOLSET address-model=$BITS architecture=x86 \
		binary-format=$FORMAT target-os=$TARGET threadapi=$THREAD \
		mc-compiler=$CROSS-windmc release install || exit 1
	touch "$ROOT/have.boost" || exit 1
	cd ../.. || exit 1
fi

if [ ! -f "$ROOT/have.openssl" ]; then
	build_fetch openssl-1.0.2p.tar.gz \
		50a98e07b1a89eb8f6a99477f262df71c6fa7bef77df4dc83025a2845c827d00 \
		https://www.openssl.org/source/openssl-1.0.2p.tar.gz || \
		exit 1
	cd dep || exit 1
	tar xzf "$ROOT/openssl-1.0.2p.tar.gz" || exit 1
	cd openssl-1.0.2p || exit 1
	TARGET=mingw
	PREFIX="$CROSS-"
	./Configure $TARGET$( [ "$BITS" = 64 ] && echo 64 ) no-shared \
		"--prefix=$ROOT/root" || exit 1
	sed -i'' 's/-Wa,--noexecstack//' Makefile || exit 1
	$MAKE CC=${PREFIX}gcc RANLIB=${PREFIX}ranlib LD=${PREFIX}ld \
		MAKEDEPPROG=${PREFIX}gcc RC=${PREFIX}windres || exit 1
	$MAKE install || exit 1
	touch "$ROOT/have.openssl" || exit 1
	cd ../.. || exit 1
fi

if [ ! -f "$ROOT/have.libevent" ]; then
	build_fetch libevent-2.1.8-stable.tar.gz \
		965cc5a8bb46ce4199a47e9b2c9e1cae3b137e8356ffdad6d94d3b9069b71dc2 \
		https://github.com/libevent/libevent/releases/download/release-2.1.8-stable/libevent-2.1.8-stable.tar.gz || \
		exit 1
	cd dep || exit 1
	tar xzf "$ROOT/libevent-2.1.8-stable.tar.gz" || exit 1
	cd libevent-2.1.8-stable || exit 1
	CFLAGS="-I$ROOT/root/include" LDFLAGS="-L$ROOT/root/lib" \
		./configure "--prefix=$ROOT/root" --enable-static \
		--disable-shared --host=$CROSS || exit 1
	sed -i'' 's/^LIBS = .*/& -lcrypt32 -lgdi32 -luser32 -lws2_32/' \
		Makefile || exit 1
	$MAKE install || exit 1
	touch "$ROOT/have.libevent" || exit 1
	cd ../.. || exit 1
fi

if [ ! -f "$ROOT/have.qt-tools" ]; then
	build_fetch qt-everywhere-opensource-src-5.9.7.tar.xz \
		1c3852aa48b5a1310108382fb8f6185560cefc3802e81ecc099f4e62ee38516c \
		https://download.qt.io/archive/qt/5.9/5.9.7/single/qt-everywhere-opensource-src-5.9.7.tar.xz || \
		exit 1
	cd dep || exit 1
	tar xJf "$ROOT/qt-everywhere-opensource-src-5.9.7.tar.xz" || exit 1
	cd qt-everywhere-opensource-src-5.9.7 || exit 1
	./configure -confirm-license -release -opensource -nomake examples \
		-nomake tests -skip qtactiveqt -skip qtenginio -skip qtlocation \
		-skip qtmultimedia -skip qtserialport -skip qtquick1 \
		-skip qtquickcontrols -skip qtscript -skip qtsensors \
		-skip qtwebsockets -skip qtxmlpatterns -skip qt3d \
		-prefix "$ROOT/root" -no-opengl -sse2 || exit 1
	$MAKE || exit 1
	$MAKE install || exit 1
	touch "$ROOT/have.qt-tools" || exit 1
	cd ../.. || exit 1
fi

if [ ! -f "$ROOT/have.qt-libs" ]; then
	build_fetch qt-everywhere-opensource-src-5.9.7.tar.xz \
		1c3852aa48b5a1310108382fb8f6185560cefc3802e81ecc099f4e62ee38516c \
		https://download.qt.io/archive/qt/5.9/5.9.7/single/qt-everywhere-opensource-src-5.9.7.tar.xz || \
		exit 1
	cd dep || exit 1
	rm -rf qt-everywhere-opensource-src-5.9.7 || exit 1
	tar xJf "$ROOT/qt-everywhere-opensource-src-5.9.7.tar.xz" || exit 1
	cd qt-everywhere-opensource-src-5.9.7 || exit 1
	./configure -confirm-license -release -opensource -nomake examples \
		-nomake tests -skip qtactiveqt -skip qtenginio -skip qtlocation \
		-skip qtmultimedia -skip qtserialport -skip qtquick1 \
		-skip qtquickcontrols -skip qtscript -skip qtsensors \
		-skip qtwebsockets -skip qtxmlpatterns -skip qt3d \
		-platform linux-g++-64 -xplatform win32-g++ -prefix "$ROOT/root" \
		-hostprefix "$ROOT/root" -no-opengl -sse2 -openssl-linked \
		-device-option CROSS_COMPILE=$CROSS- -openssl -openssl-linked \
		OPENSSL_LIBS='-lssl -lcrypto -lcrypt32 -lws2_32 -lgdi32 -luser32' \
		-L "$ROOT/root/lib" -I "$ROOT/root/include" || exit 1
	$MAKE || exit 1
	$MAKE install || exit 1
	touch "$ROOT/have.qt-libs" || exit 1
	cd ../.. || exit 1
fi

if [ ! -f "$ROOT/have.protobuf" ]; then
	build_fetch protobuf-cpp-3.6.1.tar.gz \
		b3732e471a9bb7950f090fd0457ebd2536a9ba0891b7f3785919c654fe2a2529 \
		https://github.com/protocolbuffers/protobuf/releases/download/v3.6.1/protobuf-cpp-3.6.1.tar.gz || \
		exit 1
	cd dep || exit 1
	tar xzf "$ROOT/protobuf-cpp-3.6.1.tar.gz" || exit 1
	cd protobuf-3.6.1 || exit 1
	./configure --enable-static --disable-shared "--prefix=$ROOT/root" \
		--host=$CROSS || exit 1
	$MAKE install || exit 1
	touch "$ROOT/have.protobuf" || exit 1
	cd ../.. || exit 1
fi

if [ ! -f "$ROOT/have.protoc" ]; then
	build_fetch protoc-3.6.1-linux-x86_64.zip \
		6003de742ea3fcf703cfec1cd4a3380fd143081a2eb0e559065563496af27807 \
		https://github.com/protocolbuffers/protobuf/releases/download/v3.6.1/protoc-3.6.1-linux-x86_64.zip || \
		exit 1
	cd dep || exit 1
	mkdir protc || exit 1
	cd protc || exit 1
	unzip "$ROOT/protoc-3.6.1-linux-x86_64.zip" || exit 1
	cp bin/protoc "$ROOT/root/bin" || exit 1
	touch "$ROOT/have.protoc" || exit 1
	cd ../.. || exit 1
fi

if [ ! -f "$ROOT/have.zlib" ]; then
	build_fetch zlib-1.2.11.tar.xz \
		4ff941449631ace0d4d203e3483be9dbc9da454084111f97ea0a2114e19bf066 \
		https://zlib.net/zlib-1.2.11.tar.xz || exit 1
	cd dep || exit 1
	tar xJf "$ROOT/zlib-1.2.11.tar.xz" || exit 1
	cd zlib-1.2.11 || exit 1
	CROSS_PREFIX=$CROSS- ./configure --static "--prefix=$ROOT/root" || \
		exit 1
	$MAKE install || exit 1
	touch "$ROOT/have.zlib" || exit 1
	cd ../.. || exit 1
fi

if [ ! -f "$ROOT/have.libpng" ]; then
	build_fetch libpng-1.6.34.tar.xz \
		2f1e960d92ce3b3abd03d06dfec9637dfbd22febf107a536b44f7a47c60659f6 \
		ftp://ftp-osl.osuosl.org/pub/libpng/src/libpng16/libpng-1.6.34.tar.xz || \
		exit 1
	cd dep || exit 1
	tar xJf "$ROOT/libpng-1.6.34.tar.xz" || exit 1
	cd libpng-1.6.34 || exit 1
	LDFLAGS="-L$ROOT/root/lib" CFLAGS="-I$ROOT/root/include" \
		CPPFLAGS="-I$ROOT/root/include" ./configure --enable-static \
		--disable-shared "--prefix=$ROOT/root" --host=$CROSS || exit 1
	$MAKE install || exit 1
	touch "$ROOT/have.libpng" || exit 1
	cd ../.. || exit 1
fi

if [ ! -f configure ]; then
	./autogen.sh || exit 1
fi
LDFLAGS="-L$ROOT/root/lib" CXXFLAGS="-I$ROOT/root/include -Wa,-mbig-obj" ./configure \
	"--prefix=$PWD/build" "--with-boost=$ROOT/root" --with-gui=qt5 \
	"--with-qt-libdir=$ROOT/root/lib" \
	"--with-qt-incdir=$ROOT/root/include" \
	"--with-qt-bindir=$ROOT/root/bin" \
	"--with-protoc-bindir=$ROOT/root/bin" --disable-tests \
	--disable-gui-tests --disable-bench --host=$CROSS || exit 1
rm -rf build || exit 1
$MAKE V=1 install || exit 1

find build/bin -maxdepth 1 -type f ! -name "${COIN}d*" \
	! -name "$COIN-cli*" ! -name "$COIN-tx*" ! -name "$COIN-qt*" \
	-delete || exit 1
for DLL in Qt5Core.dll Qt5Gui.dll Qt5Network.dll Qt5Widgets.dll; do
	cp "$ROOT/root/bin/$DLL" build/bin || exit 1
done
mkdir -p build/bin/plugins/platforms || exit 1
cp "$ROOT/root/plugins/platforms/qwindows.dll" \
	build/bin/plugins/platforms || exit 1
GCCVER="$( $CROSS-g++ --version | head -n1 | sed 's/.*) \([0-9\.]*\) .*/\1/;s/\.0$//g' )"
if [ "$BITS" = 64 ]; then
	cp "/usr/lib/gcc/$CROSS/$GCCVER-posix/libgcc_s_seh-1.dll" \
		build/bin || exit 1
else
	cp "/usr/lib/gcc/$CROSS/$GCCVER-posix/libgcc_s_sjlj-1.dll" \
		build/bin || exit 1
fi
cp "/usr/lib/gcc/$CROSS/$GCCVER-posix/libstdc++-6.dll" \
	"/usr/$CROSS/lib/libwinpthread-1.dll" build/bin || exit 1
find build/bin -type f -exec chmod -x {} \; || exit 1
echo '[Paths]' | tee build/bin/qt.conf > /dev/null || exit 1
echo 'Plugins = ./plugins' | tee -a build/bin/qt.conf > \
	/dev/null || exit 1
cd build/bin || exit 1
find . -type f -exec strip -s {} \; || exit 1
zip -r9 "$BASE/${COIN}_${VERSION}_$OS$BITS.zip" * || exit 1
