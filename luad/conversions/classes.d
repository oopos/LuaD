/**
Internal module for pushing and getting class types.
This feature is still a work in progress, currently, only the simplest of _classes are supported.
See the source code for details.
*/
module luad.conversions.classes;

import luad.conversions.functions;

import luad.c.all;
import luad.stack;

import core.memory;

import std.traits;
import std.string : toStringz;

extern(C) private int classCleaner(lua_State* L)
{
	GC.removeRoot(lua_touserdata(L, 1));
	return 0;
}

private void pushMeta(T)(lua_State* L, T obj)
{
	if(luaL_newmetatable(L, toStringz(T.mangleof)) == 0)
		return;
	
	pushValue(L, T.stringof);
	lua_setfield(L, -2, "__dclass");
	
	pushValue(L, T.mangleof);
	lua_setfield(L, -2, "__dmangle");
	
	lua_newtable(L); //__index fallback table
	
	foreach(member; __traits(derivedMembers, T))
	{
		static if(member != "this" && member != "__ctor" && //do not handle
			member != "Monitor" && member != "toHash" && //do not handle
			member != "toString" && member != "opEquals" && //handle below
			member != "opCmp") //handle below
		{
			static if(__traits(getOverloads, T.init, member).length > 0)
			{
				pushMethod!(T, member)(L);
				lua_setfield(L, -2, toStringz(member));
			}
		}
	}
	
	lua_setfield(L, -2, "__index");
	
	pushMethod!(T, "toString")(L);
	lua_setfield(L, -2, "__tostring");
	
	pushMethod!(T, "opEquals")(L);
	lua_setfield(L, -2, "__eq");

	//TODO: handle opCmp here

	
	lua_pushcfunction(L, &classCleaner);
	lua_setfield(L, -2, "__gc");
	
	lua_pushvalue(L, -1);
	lua_setfield(L, -2, "__metatable");
}

void pushClassInstance(T)(lua_State* L, T obj) if (is(T == class))
{	
	T* ud = cast(T*)lua_newuserdata(L, obj.sizeof);
	*ud = obj;
	
	pushMeta(L, obj);
	lua_setmetatable(L, -2);
	
	GC.addRoot(ud);
}

//TODO: handle foreign userdata properly (i.e. raise errors)
T getClassInstance(T)(lua_State* L, int idx) if (is(T == class))
{
	if(lua_getmetatable(L, idx) == 0)
	{
		luaL_error(L, "attempt to get 'userdata: %p' as a D object", lua_topointer(L, idx));
	}
	
	lua_getfield(L, -1, "__dmangle"); //must be a D object
	
	static if(!is(T == Object)) //must be the right object
	{
		size_t manglelen;
		auto cmangle = lua_tolstring(L, -1, &manglelen);
		if(cmangle[0 .. manglelen] != T.mangleof)
		{
			lua_getfield(L, -2, "__dclass");
			auto cname = lua_tostring(L, -1);
			luaL_error(L, `attempt to get instance %s as type "%s"`, cname, toStringz(T.stringof));
		}
	}
	lua_pop(L, 2); //metatable and metatable.__dmangle
	
	Object obj = *cast(Object*)lua_touserdata(L, idx);
	return cast(T)obj;
}

version(unittest) import luad.testing;

unittest
{
	lua_State* L = luaL_newstate();
	scope(success) lua_close(L);
	
	static class A
	{
		private:
		string s;

		public:
		int n;
		
		this(int n, string s)
		{
			this.n = n;
			this.s = s;
		}
		
		string foo(){ return s; }
		
		int bar(int i)
		{
			return n += i;
		}
	}

	static class B : A
	{
		this(int a, string s)
		{
			super(a, s);
		}

		override string foo() { return "B"; }

		override string toString() { return "B"; }
	}

	void addA(in char* name, A a)
	{
		pushValue(L, a);
		lua_setglobal(L, name);
	}
	
	auto a = new A(2, "foo");
	addA("a", a);

	pushValue(L, a.toString());
	lua_setglobal(L, "a_toString");
	
	auto b = new B(2, "foo");
	addA("b", b);
	addA("otherb", b);
	
	pushValue(L, (A a)
	{
		assert(a);
		a.bar(2);
	});
	lua_setglobal(L, "func");
	
	luaL_openlibs(L);
	unittest_lua(L, `
		assert(a:bar(2) == 4)
		func(a)
		assert(a:bar(2) == 8)

		assert(a:foo() == "foo")
		assert(tostring(a) == a_toString)

		assert(b:bar(2) == 4)
		func(b)
		assert(b:bar(2) == 8)

		assert(b:foo() == "B")
		assert(tostring(b) == "B")

		assert(a ~= b)
		assert(b == otherb)
	`);
}