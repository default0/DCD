/**
 * This file is part of DCD, a development tool for the D programming language.
 * Copyright (C) 2014 Brian Schott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

module server.server;

import core.sys.posix.sys.stat;
import std.algorithm;
import std.array;
import std.conv;
import std.datetime;
import std.exception : enforce;
import std.experimental.allocator;
import std.experimental.allocator.mallocator;
import std.experimental.logger;
import std.file;
import std.file;
import std.getopt;
import std.path;
import std.process;
import std.socket;
import std.stdio;

import msgpack;

import dsymbol.string_interning;

import common.dcd_version;
import common.messages;
import common.socket;
import dsymbol.modulecache;
import dsymbol.symbol;
import server.autocomplete;

/// Name of the server configuration file
enum CONFIG_FILE_NAME = "dcd.conf";

version(linux) version = useXDG;
version(BSD) version = useXDG;
version(FreeBSD) version = useXDG;
version(OSX) version = useXDG;

int main(string[] args)
{
	ushort port = 9166;
	bool help;
	bool printVersion;
	bool ignoreConfig;
	string[] importPaths;
	LogLevel level = globalLogLevel;
	version(Windows)
	{
		bool useTCP = true;
		string socketFile;
	}
	else
	{
		bool useTCP = false;
		string socketFile = generateSocketName();
	}

	try
	{
		getopt(args, "port|p", &port, "I", &importPaths, "help|h", &help,
			"version", &printVersion, "ignoreConfig", &ignoreConfig,
			"logLevel", &level, "tcp", &useTCP, "socketFile", &socketFile);
	}
	catch (ConvException e)
	{
		fatal(e.msg);
		printHelp(args[0]);
		return 1;
	}

	if (printVersion)
	{
		version (Windows)
			writeln(DCD_VERSION);
		else version (built_with_dub)
			writeln(DCD_VERSION);
		else
			write(DCD_VERSION, " ", GIT_HASH);
		return 0;
	}

	if (help)
	{
		printHelp(args[0]);
		return 0;
	}

	version (Windows) if (socketFile !is null)
	{
		fatal("UNIX domain sockets not supported on Windows");
		return 1;
	}

	globalLogLevel = level;

	info("Starting up...");
	StopWatch sw = StopWatch(AutoStart.yes);

	if (!ignoreConfig)
		importPaths ~= loadConfiguredImportDirs();

	Socket socket;
	if (useTCP)
	{
		socket = new TcpSocket(AddressFamily.INET);
		socket.blocking = true;
		socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
		socket.bind(new InternetAddress("localhost", port));
		info("Listening on port ", port);
	}
	else
	{
		socket = new Socket(AddressFamily.UNIX, SocketType.STREAM);
		if (exists(socketFile))
		{
			info("Cleaning up old socket file at ", socketFile);
			remove(socketFile);
		}
		socket.blocking = true;
		socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
		socket.bind(new UnixAddress(socketFile));
		setAttributes(socketFile, S_IRUSR | S_IWUSR);
		info("Listening at ", socketFile);
	}
	socket.listen(0);

	scope (exit)
	{
		info("Shutting down sockets...");
		socket.shutdown(SocketShutdown.BOTH);
		socket.close();
		if (!useTCP)
			remove(socketFile);
		info("Sockets shut down.");
	}

	ModuleCache cache = ModuleCache(new ASTAllocator);
	cache.addImportPaths(importPaths);
	infof("Import directories:\n    %-(%s\n    %)", cache.getImportPaths());

	ubyte[] buffer = cast(ubyte[]) Mallocator.instance.allocate(1024 * 1024 * 4); // 4 megabytes should be enough for anybody...
	scope(exit) Mallocator.instance.deallocate(buffer);

	sw.stop();
	info(cache.symbolsAllocated, " symbols cached.");
	info("Startup completed in ", sw.peek().to!("msecs", float), " milliseconds.");

	// No relative paths
	version (Posix) chdir("/");

	version (LittleEndian)
		immutable expectedClient = IPv4Union([1, 0, 0, 127]);
	else
		immutable expectedClient = IPv4Union([127, 0, 0, 1]);

	serverLoop: while (true)
	{
		auto s = socket.accept();
		s.blocking = true;

		if (useTCP)
		{
			// Only accept connections from localhost
			IPv4Union actual;
			InternetAddress clientAddr = cast(InternetAddress) s.remoteAddress();
			actual.i = clientAddr.addr;
			// Shut down if somebody tries connecting from outside
			if (actual.i != expectedClient.i)
			{
				fatal("Connection attempted from ", clientAddr.toAddrString());
				return 1;
			}
		}

		scope (exit)
		{
			s.shutdown(SocketShutdown.BOTH);
			s.close();
		}
		ptrdiff_t bytesReceived = s.receive(buffer);

		auto requestWatch = StopWatch(AutoStart.yes);

		size_t messageLength;
		// bit magic!
		(cast(ubyte*) &messageLength)[0..size_t.sizeof] = buffer[0..size_t.sizeof];
		while (bytesReceived < messageLength + size_t.sizeof)
		{
			immutable b = s.receive(buffer[bytesReceived .. $]);
			if (b == Socket.ERROR)
			{
				bytesReceived = Socket.ERROR;
				break;
			}
			bytesReceived += b;
		}

		if (bytesReceived == Socket.ERROR)
		{
			warning("Socket recieve failed");
			break;
		}

		AutocompleteRequest request;
		msgpack.unpack(buffer[size_t.sizeof .. bytesReceived], request);
		if (request.kind & RequestKind.clearCache)
		{
			info("Clearing cache.");
			cache.clear();
		}
		else if (request.kind & RequestKind.shutdown)
		{
			info("Shutting down.");
			break serverLoop;
		}
		else if (request.kind & RequestKind.query)
		{
			AutocompleteResponse response;
			response.completionType = "ack";
			ubyte[] responseBytes = msgpack.pack(response);
			s.send(responseBytes);
			continue;
		}
		if (request.kind & RequestKind.addImport)
		{
			cache.addImportPaths(request.importPaths);
		}
		if (request.kind & RequestKind.listImports)
		{
			AutocompleteResponse response;
			response.importPaths = cache.getImportPaths().array();
			ubyte[] responseBytes = msgpack.pack(response);
			info("Returning import path list");
			s.send(responseBytes);
		}
		else if (request.kind & RequestKind.autocomplete)
		{
			info("Getting completions");
			AutocompleteResponse response = complete(request, cache);
			ubyte[] responseBytes = msgpack.pack(response);
			s.send(responseBytes);
		}
		else if (request.kind & RequestKind.doc)
		{
			info("Getting doc comment");
			try
			{
				AutocompleteResponse response = getDoc(request, cache);
				ubyte[] responseBytes = msgpack.pack(response);
				s.send(responseBytes);
			}
			catch (Exception e)
			{
				warning("Could not get DDoc information", e.msg);
			}
		}
		else if (request.kind & RequestKind.symbolLocation)
		{
			try
			{
				AutocompleteResponse response = findDeclaration(request, cache);
				ubyte[] responseBytes = msgpack.pack(response);
				s.send(responseBytes);
			}
			catch (Exception e)
			{
				warning("Could not get symbol location", e.msg);
			}
		}
		else if (request.kind & RequestKind.search)
		{
			AutocompleteResponse response = symbolSearch(request, cache);
			ubyte[] responseBytes = msgpack.pack(response);
			s.send(responseBytes);
		}
		info("Request processed in ", requestWatch.peek().to!("msecs", float), " milliseconds");
	}
	return 0;
}

/**
 * Locates the configuration file
 */
string getConfigurationLocation()
{
	version (useXDG)
	{
		string configDir = environment.get("XDG_CONFIG_HOME", null);
		if (configDir is null)
		{
			configDir = environment.get("HOME", null);
			if (configDir !is null)
				configDir = buildPath(configDir, ".config", "dcd", CONFIG_FILE_NAME);
			if (!exists(configDir))
				configDir = buildPath("/etc/", CONFIG_FILE_NAME);
		}
		else
		{
			configDir = buildPath(configDir, "dcd", CONFIG_FILE_NAME);
		}
		return configDir;
	}
	else version(Windows)
	{
		return CONFIG_FILE_NAME;
	}
}

/// IP v4 address as bytes and a uint
union IPv4Union
{
	/// the bytes
	ubyte[4] b;
	/// the uint
	uint i;
}

/**
 * Prints a warning message to the user when an old config file is detected.
 */
void warnAboutOldConfigLocation()
{
	version (linux) if ("~/.config/dcd".expandTilde().exists()
		&& "~/.config/dcd".expandTilde().isFile())
	{
		warning("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
		warning("!! Upgrade warning:");
		warning("!! '~/.config/dcd' should be moved to '$XDG_CONFIG_HOME/dcd/dcd.conf'");
		warning("!! or '$HOME/.config/dcd/dcd.conf'");
		warning("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
	}
}

/**
 * Loads import directories from the configuration file
 */
string[] loadConfiguredImportDirs()
{
	warnAboutOldConfigLocation();
	immutable string configLocation = getConfigurationLocation();
	if (!configLocation.exists())
		return [];
	info("Loading configuration from ", configLocation);
	File f = File(configLocation, "rt");
	return f.byLine(KeepTerminator.no)
		.filter!(a => a.length > 0 && a[0] != '#' && existanceCheck(a))
		.map!(a => a.idup)
		.array();
}

/**
 * Implements the --help switch.
 */
void printHelp(string programName)
{
    writefln(
`
    Usage: %s options

options:
    -I PATH
        Includes PATH in the listing of paths that are searched for file
        imports.

    --help | -h
        Prints this help message.

    --version
        Prints the version number and then exits.

    --port PORTNUMBER | -pPORTNUMBER
        Listens on PORTNUMBER instead of the default port 9166 when TCP sockets
        are used.

    --logLevel LEVEL
        The logging level. Valid values are 'all', 'trace', 'info', 'warning',
        'error', 'critical', 'fatal', and 'off'.

    --tcp
        Listen on a TCP socket instead of a UNIX domain socket. This switch
        has no effect on Windows.

    --socketFile FILENAME
        Use the given FILENAME as the path to the UNIX domain socket. Using
        this switch is an error on Windows.`, programName);
}
