module direntry;

import std.datetime.systime : Clock, SysTime, unixTimeToStdTime;
import std.internal.cstring;
import std.meta;
import std.range.primitives;
import std.traits;
import std.typecons;
import std.algorithm : canFind;
import std.stdio : writeln;


version ( Windows )
{
    import core.sys.windows.winbase, core.sys.windows.winnt, std.windows.syserror;
}

version ( Windows )
{
    private alias FSChar = WCHAR;       // WCHAR can be aliased to wchar or wchar_t
}

version ( Windows ) 
{
    private 
    ulong makeUlong( DWORD dwLow, DWORD dwHigh ) @safe pure nothrow @nogc
    {
        ULARGE_INTEGER li;
        li.LowPart  = dwLow;
        li.HighPart = dwHigh;

        return li.QuadPart;
    }
}

version ( Windows )
{
    import std.datetime.systime : FILETIMEToSysTime;
}


class FileException : Exception
{
    this( ARGS )( ARGS args... )
    {
        super( args );
    }
}


struct DirEntry
{
@safe:
public:
    string name;
    alias name this;

    WIN32_FIND_DATAW _fd;


    this( string pathname ) @trusted
    {
        name = pathname;
        readAttributes();
    }


    /** */
    void readAttributes() @trusted
    {
        if ( isRootPath( name ) )
        {
            if ( getFileAttributesWin( name, cast( WIN32_FILE_ATTRIBUTE_DATA* ) &_fd ) )
            {
                //
            }
            else
            {
                // FAIL
            }
        }
        else
        {
            HANDLE hFind = FindFirstFileW( name.tempCString!FSChar(), &_fd );

            if ( hFind == INVALID_HANDLE_VALUE )
            {
                // FAIL
            }
            else
            {
                FindClose( hFind );
            }
        }
    }


    /** */
    alias Tuple!( bool, "hasParent", DirEntry, "parent" ) ParentResult;

    /** */
    ParentResult parent()
    {
        import std.path : dirName;

        auto parentPath = name.dirName;

        //
        ParentResult result;

        if ( parentPath && ( parentPath != name ) )
        {
            result.hasParent   = true;
            result.parent.name = parentPath;
            result.parent.readAttributes();
        }

        return result;
    }


    /** */
    auto childs() @trusted
    {
        return DirIterator( name );
    }


    void updateName( string path ) @trusted
    {
        import core.stdc.wchar_ : wcslen;
        import std.path         : buildPath;
        import std.conv         : to;

        size_t clength = wcslen( &_fd.cFileName[ 0 ] );
        name = buildPath( path, _fd.cFileName[ 0 .. clength ].to!string );
    }


    @property 
    bool isDir() const pure nothrow
    {
        return ( _fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY ) != 0;
    }

    @property 
    bool isFile() const pure nothrow
    {
        //Are there no options in Windows other than directory and file?
        //If there are, then this probably isn't the best way to determine
        //whether this DirEntry is a file or not.
        return !isDir;
    }

    @property 
    bool isSymlink() const pure nothrow
    {
        return ( _fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT ) != 0;
    }

    @property 
    ulong size() const pure nothrow
    {
        return makeUlong( _fd.nFileSizeLow, _fd.nFileSizeHigh );
    }

    @property 
    SysTime timeCreated() const nothrow
    {
        return trustedFILETIMEToSysTime( &_fd.ftCreationTime );
    }

    @property 
    SysTime timeLastAccessed() const nothrow
    {
        return trustedFILETIMEToSysTime( &_fd.ftLastAccessTime );
    }

    @property 
    SysTime timeLastModified() const nothrow
    {
        return trustedFILETIMEToSysTime( &_fd.ftLastWriteTime );
    }

    @property 
    uint attributes() const pure nothrow
    {
        return _fd.dwFileAttributes;
    }

    @property 
    uint linkAttributes() const pure nothrow
    {
        return _fd.dwFileAttributes;
    }
}


version ( Windows) 
{
    bool isRootPath( string path )
    {
        // File path formats on Windows systems:
        //   https://docs.microsoft.com/en-us/dotnet/standard/io/file-path-formats
        // "\"
        // "C:\"
        // "\\.\C:\"
        // "\\?\C:\"
        // "\\.\Volume{b75e2c83-0000-0000-0000-602f00000000}\"
        // "\\system07\C$\"

        if ( path == r"\" )
        {
            return true;
        }

        if ( path.length == 3 && isDosDriveLetter( path[ 0 ] ) && path[ 1 .. $ ] == r":\" )
        {
            return true;
        }

        if ( path == r"\\.\" )
        {
            return true;
        }

        if ( path == r"\\?\" )
        {
            return true;
        }

        if ( path.length > 2 && path[ 0 .. 2 ] == r"\\" && !hasSlashes( path[ 2 .. $ ] ) )
        {
            return true;
        }

        return false;
    } 


    bool isDosDriveLetter( wchar c )
    {
        if ( c >= 'A' && c <= 'Z' )
        {
            return true;
        }

        if ( c >= 'a' && c <= 'z' )
        {
            return true;
        }

        return false;
    }


    bool hasSlashes( string s )
    {
        return s.canFind( '\\' );
    }
}


SysTime trustedFILETIMEToSysTime( const( FILETIME )* ft ) nothrow @trusted 
{
    import std.datetime.systime : FILETIMEToSysTime;

    try { return cast( SysTime ) FILETIMEToSysTime( ft ); }
    catch ( Exception e ) { return SysTime(); }
}



version ( Windows) 
private 
bool getFileAttributesWin( R )( R name, WIN32_FILE_ATTRIBUTE_DATA* fad )
  if ( isInputRange!R && !isInfinite!R && isSomeChar!( ElementEncodingType!R ) )
{
    auto namez = name.tempCString!FSChar();

    auto res =
        GetFileAttributesExW( 
            namez, 
            GET_FILEEX_INFO_LEVELS.GetFileExInfoStandard, 
            fad 
        );

    return cast( bool ) res;
}



version ( Windows )
{
    private struct DirIteratorImpl
    {
      @safe:
        string   _path;
        DirEntry _cur;
        HANDLE   _handle = NULL;

        
        bool toNext( bool fetch ) @trusted
        {
            import core.stdc.wchar_ : wcscmp;

            if ( fetch )
            {
                if ( FindNextFileW( _handle, &_cur._fd ) == FALSE )
                {
                    // GetLastError() == ERROR_NO_MORE_FILES
                    FindClose( _handle );
                    _handle = NULL;
                    return false;
                }
            }

            while ( wcscmp( _cur._fd.cFileName.ptr, "." ) == 0 ||
                    wcscmp( _cur._fd.cFileName.ptr, ".." ) == 0 )
            {
                if ( FindNextFileW( _handle, &_cur._fd ) == FALSE )
                {
                    // GetLastError() == ERROR_NO_MORE_FILES
                    FindClose( _handle );
                    _handle = NULL;
                    return false;
                }
            }

            //
            _cur.updateName( _path );
            
            return true;
        }


        this( string pathnameStr )
        {
            _path = pathnameStr;

            //
            import std.path : chainPath;

            auto searchPattern = chainPath( pathnameStr, "*.*" );

            static auto trustedFindFirstFileW( typeof( searchPattern ) pattern, WIN32_FIND_DATAW* fd ) @trusted
            {
                return FindFirstFileW( pattern.tempCString!FSChar(), fd );
            }

            _handle = trustedFindFirstFileW( searchPattern, &_cur._fd );

            if ( _handle == INVALID_HANDLE_VALUE )
            {
                _handle = NULL;
            }
            else
            {
                toNext( false );
            }
        }


        @property 
        bool empty()
        {
            return _handle == NULL;
        }

        
        @property 
        DirEntry front()
        {
            return _cur;
        }


        void popFront()
        {
            if ( _handle == NULL )
            {
                //;
            }
            else
            {
                toNext( true );
            }
        }


        ~this() @trusted
        {
            if ( _handle != NULL )
            {
                FindClose( _handle );
            }
        }
    }    
}


struct DirIterator
{
@safe:
    RefCounted!( DirIteratorImpl, RefCountedAutoInitialize.no ) impl;
    this( string pathname ) @trusted
    {
        impl = typeof( impl )( pathname );
    }

public:
    @property bool     empty()    { return impl.empty; }
    @property DirEntry front()    { return impl.front; }
              void     popFront() { impl.popFront(); }
}
