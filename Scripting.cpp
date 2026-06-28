#include <stdafx.h>

#include "Scripting.h"

#include "config/CETVersion.h"

#include "FunctionOverride.h"
#include "GameOptions.h"
#include "Texture.h"

#include <CET.h>
#include <lsqlite3/lsqlite3.h>
#include <reverse/Type.h>
#include <reverse/SingletonReference.h>
#include <reverse/StrongReference.h>
#include <reverse/WeakReference.h>
#include <reverse/ResourceAsyncReference.h>
#include <reverse/NativeProxy.h>
#include <reverse/RTTILocator.h>
#include <reverse/RTTIExtender.h>
#include <reverse/Converter.h>
#include <reverse/TweakDB/TweakDB.h>
#include <sol_imgui/sol_imgui.h>
#include <Utils.h>

#ifdef CET_DEBUG
#include "GameHooks.h"
#include "GameDump.h"
#include <RED4ext/Dump/Reflection.hpp>
#endif

static constexpr bool s_cThrowLuaErrors = true;

static RTTILocator s_stringType{RED4ext::FNV1a64("String")};
static RTTILocator s_resRefType{RED4ext::FNV1a64("redResourceReferenceScriptToken")};

Scripting::Scripting(const Paths& aPaths, const Options& aOptions, VKBindings& aBindings, D3D12& aD3D12)
    : m_sandbox(this, aBindings)
    , m_mapper(m_lua.AsRef(), m_sandbox)
    , m_store(m_sandbox, aPaths, aBindings)
    , m_override(this)
    , m_paths(aPaths)
    , m_options(aOptions)
    , m_d3d12(aD3D12)
{
    CreateLogger(aPaths.CETRoot() / "scripting.log", "scripting");
    CreateLogger(aPaths.CETRoot() / "gamelog.log", "gamelog");
}

void Scripting::Initialize()
{
    auto lua = m_lua.Lock();
    auto& luaVm = lua.Get();

    luaVm.open_libraries(sol::lib::base, sol::lib::string, sol::lib::io, sol::lib::math, sol::lib::package, sol::lib::os, sol::lib::table, sol::lib::bit32);

    if (m_options.Developer.EnableJIT)
        luaVm.open_libraries(sol::lib::jit);

    luaVm.require("sqlite3", luaopen_lsqlite3);

    // make sure to set package path to current directory scope
    // as this could get overriden by LUA_PATH environment variable
    luaVm["package"]["path"] = "./?.lua";

    // execute autoexec.lua inside our default script directory
    const auto previousCurrentPath = std::filesystem::current_path();
    current_path(m_paths.CETRoot() / "scripts");
    luaVm.script("json = require 'json/json'", sol::detail::default_chunk_name(), sol::load_mode::text);
    luaVm.script("IconGlyphs = require 'IconGlyphs/icons'", sol::detail::default_chunk_name(), sol::load_mode::text);
    current_path(previousCurrentPath);

    // initialize sandbox
    m_sandbox.Initialize();

    auto& globals = m_sandbox.GetGlobals();

    // load in imgui bindings
    sol_ImGui::InitBindings(luaVm, globals);
    sol::table imgui = globals["ImGui"];
    Texture::BindTexture(imgui);
    sol_ToastNotification::BindImNotifyToast(imgui);
    for (auto [key, value] : imgui)
    {
        if (value.get_type() != sol::type::function)
            continue;

        sol::function original = value;
        imgui[key] = make_object(
            luaVm,
            [this, original](sol::variadic_args aVariadicArgs, sol::this_environment aThisEnv) -> sol::variadic_results
            {
                const sol::environment cEnv = aThisEnv;
                const auto logger = cEnv["__logger"].get<std::shared_ptr<spdlog::logger>>();
                if (!m_sandbox.GetImGuiAvailable())
                {
                    logger->error("Tried to call ImGui from invalid event!");
                    throw "Tried to call ImGui from invalid event!";
                }

                return original(as_args(aVariadicArgs));
            });
    }

    // setup logger for console sandbox
    auto& consoleSB = m_sandbox[0];
    auto& consoleSBEnv = consoleSB.GetEnvironment();
    consoleSBEnv["__logger"] = spdlog::get("scripting");

    // load in game bindings
    globals["print"] = [](sol::variadic_args aArgs, sol::this_state aState)
    {
        std::ostringstream oss;
        sol::state_view s(aState);
        for (auto it = aArgs.cbegin(); it != aArgs.cend(); ++it)
        {
            if (it != aArgs.cbegin())
            {
                oss << " ";
            }
            std::string str = s["tostring"]((*it).get<sol::object>());
            oss << str;
        }

        spdlog::get("scripting")->info(oss.str());
    };

    globals["GetVersion"] = []() -> std::string
    {
        return CET_GIT_TAG;
    };

    globals["GetDisplayResolution"] = [this]() -> std::tuple<float, float>
    {
        const auto resolution = m_d3d12.GetResolution();
        return {static_cast<float>(resolution.cx), static_cast<float>(resolution.cy)};
    };

    globals["ModArchiveExists"] = [this](const std::string& acArchiveName) -> bool
    {
        const auto resourceDepot = RED4ext::ResourceDepot::Get();

        for (const auto& archiveGroup : resourceDepot->groups)
        {
            if (archiveGroup.scope == RED4ext::ArchiveScope::Mod)
            {
                for (const auto& archive : archiveGroup.archives)
                {
                    auto archivePath = std::filesystem::path(archive.path.c_str());
                    if (archivePath.filename() == acArchiveName)
                        return true;
                }
            }
        }

        return false;
    };

    // --- MERCENARY LOOP NATIVE COMMAND ---
    globals["ForceMercReset"] = []() -> std::string
    {
        // 1. Log to the CET console/file
        spdlog::get("scripting")->info("[MercenaryLoop] Native Sector Flush Initiated.");

        // FOR LATER:
        // RED4ext::CGameEngine* engine = RED4ext::CGameEngine::Get();
        // Here we will inject the PopulationSystem or StreamingWorld pointer.

        return "C++ Hook Successful! Ready for RED4ext Pointer Injection.";
    };


  // --- MERCENARY LOOP SECTOR FLUSH ---
    globals["ForceMercReset"] = [](sol::this_environment aThisEnv) -> std::string
    {
        spdlog::get("scripting")->info("[MercenaryLoop] Attempting to hook worldStreamingWorld...");

        RED4ext::CRTTISystem* rtti = RED4ext::CRTTISystem::Get();
        RED4ext::CClass* streamingClass = rtti->GetClass("worldStreamingWorld");

        if (streamingClass)
        {
            spdlog::get("scripting")->info("SUCCESS: worldStreamingWorld class pointer acquired!");

            // Crawl up the inheritance tree to catch all methods
            RED4ext::CClass* currentClass = streamingClass;
            while (currentClass)
            {
                spdlog::get("scripting")->info("--- Methods for Class: {} ---", currentClass->name.ToString());

                // Access the RED4ext public array directly
                for (auto* method : currentClass->funcs)
                {
                    if (method)
                    {
                        spdlog::get("scripting")->info("Method: {}", method->fullName.ToString());
                    }
                }
                currentClass = currentClass->parent; // Move up to the parent class
            }
            spdlog::get("scripting")->info("---------------------------------------------");

            return "StreamingWorld Hooked! Check gamelog.log for the Method Dump.";
        }
        else
        {
            spdlog::get("scripting")->error("CRITICAL: Failed to locate worldStreamingWorld.");
            return "Hook Failed.";
        }
    };
    // -----------------------------------

    // load mods
    m_store.LoadAll();
}

void Scripting::PostInitializeScripting()
{
    auto lua = m_lua.Lock();
    auto& luaVm = lua.Get();
    auto& globals = m_sandbox.GetGlobals();

    if (luaVm["__Game"] != sol::nil)
    {
        m_mapper.Refresh();
        m_override.Refresh();
        return;
    }

    luaVm.new_usertype<Scripting>("__Game", sol::meta_function::construct, sol::no_constructor, sol::meta_function::index, &Scripting::Index);

    luaVm.new_usertype<Type>("__Type", sol::meta_function::construct, sol::no_constructor, sol::meta_function::index, &Type::Index, sol::meta_function::new_index, &Type::NewIndex);

    luaVm.new_usertype<ClassType>(
        "__ClassType", sol::meta_function::construct, sol::no_constructor, sol::base_classes, sol::bases<Type>(), sol::meta_function::index, &ClassType::Index,
        sol::meta_function::new_index, &ClassType::NewIndex);

    globals.new_usertype<Type::Descriptor>("Descriptor", sol::meta_function::to_string, &Type::Descriptor::ToString);

    globals.new_usertype<StrongReference>(
        "StrongReference", sol::meta_function::construct, sol::no_constructor, sol::base_classes, sol::bases<Type, ClassType>(), sol::meta_function::index, &StrongReference::Index,
        sol::meta_function::new_index, &StrongReference::NewIndex);

    globals.new_usertype<WeakReference>(
        "WeakReference", sol::meta_function::construct, sol::no_constructor, sol::base_classes, sol::bases<Type, ClassType>(), sol::meta_function::index, &WeakReference::Index,
        sol::meta_function::new_index, &WeakReference::NewIndex);

    globals.new_usertype<SingletonReference>(
        "SingletonReference", sol::meta_function::construct, sol::no_constructor, sol::base_classes, sol::bases<Type, ClassType>(), sol::meta_function::index,
        &SingletonReference::Index, sol::meta_function::new_index, &SingletonReference::NewIndex);

    globals.new_usertype<ClassReference>(
        "ClassReference", sol::meta_function::construct, sol::no_constructor, sol::base_classes, sol::bases<Type, ClassType>(), sol::meta_function::index, &ClassReference::Index,
        sol::meta_function::new_index, &ClassReference::NewIndex);

    globals.new_usertype<ResourceAsyncReference>(
        "ResourceAsyncReference", sol::meta_function::construct, sol::no_constructor, sol::base_classes, sol::bases<Type, ClassType>(), sol::meta_function::index,
        &ResourceAsyncReference::Index, sol::meta_function::new_index, &ResourceAsyncReference::NewIndex, "hash", property(&ResourceAsyncReference::GetLuaHash));

    globals.new_usertype<UnknownType>(
        "Unknown", sol::meta_function::construct, sol::no_constructor, sol::base_classes, sol::bases<Type>(), sol::meta_function::index, &UnknownType::Index,
        sol::meta_function::new_index, &UnknownType::NewIndex);



    globals.set_function(
        "ArrayPushBack",
        [this](sol::object aObj, const std::string& acPropName, sol::object aValue) -> bool
        {
            if (aObj.is<StrongReference>())
            {
                auto* pRef = aObj.as<StrongReference*>();
                auto* pClass = static_cast<RED4ext::CClass*>(pRef->GetType());
                auto* pHandle = pRef->GetHandle();
                if (pClass && pHandle)
                    return RTTIHelper::Get().ArrayPushBack(pClass, pHandle, acPropName, aValue);
            }
            else if (aObj.is<WeakReference>())
            {
                auto* pRef = aObj.as<WeakReference*>();
                auto* pClass = static_cast<RED4ext::CClass*>(pRef->GetType());
                auto* pHandle = pRef->GetHandle();
                if (pClass && pHandle)
                    return RTTIHelper::Get().ArrayPushBack(pClass, pHandle, acPropName, aValue);
            }
            return false;
        });


    // ============================================================
    // REPLACE lines 289-402 in Scripting.cpp with this block
    // Goes right after the ArrayPushBack registration
    // ============================================================

    // ============================================================
    // DumpClassNative - Walk C++ RTTI property chain for any class
    // Returns ALL properties including native-only ones hidden from script
    // Usage: local info = DumpClassNative("questQuestsSystem")
    // ============================================================
    globals.set_function(
        "DumpClassNative",
        [](sol::this_state aState, const std::string& acClassName) -> sol::object
        {
            sol::state_view lua(aState);
            sol::table result = lua.create_table();

            RED4ext::CRTTISystem* pRtti = RED4ext::CRTTISystem::Get();
            if (!pRtti)
            {
                result["error"] = "RTTI system not available";
                return result;
            }

            RED4ext::CClass* pClass = pRtti->GetClass(acClassName.c_str());
            if (!pClass)
            {
                result["error"] = "Class not found: " + acClassName;
                return result;
            }

            result["name"] = pClass->name.ToString();
            result["size"] = pClass->size;
            result["alignment"] = pClass->alignment;

            // Walk ALL properties including inherited
            sol::table props = lua.create_table();
            int propIdx = 0;

            RED4ext::CClass* pCurrent = pClass;
            while (pCurrent != nullptr)
            {
                for (uint32_t i = 0; i < pCurrent->props.size; ++i)
                {
                    RED4ext::CProperty* pProp = pCurrent->props.entries[i];
                    if (!pProp)
                        continue;

                    sol::table p = lua.create_table();
                    p["name"] = pProp->name.ToString();
                    p["type"] = pProp->type ? pProp->type->GetName().ToString() : "unknown";
                    p["offset"] = pProp->valueOffset;
                    p["fromClass"] = pCurrent->name.ToString();
                    props[propIdx] = p;
                    propIdx++;

                }
                pCurrent = pCurrent->parent;
            }

            result["properties"] = props;
            result["totalProps"] = propIdx;

            // Walk ALL functions including inherited
            sol::table funcs = lua.create_table();
            int funcIdx = 0;

            pCurrent = pClass;
            while (pCurrent != nullptr)
            {
                for (uint32_t i = 0; i < pCurrent->funcs.size; ++i)
                {
                    if (pCurrent->funcs.entries[i])
                    {
                        sol::table f = lua.create_table();
                        f["name"] = pCurrent->funcs.entries[i]->fullName.ToString();
                        f["shortName"] = pCurrent->funcs.entries[i]->shortName.ToString();
                        f["fromClass"] = pCurrent->name.ToString();
                        funcs[funcIdx] = f;
                        funcIdx++;
                    }
                }
                for (uint32_t i = 0; i < pCurrent->staticFuncs.size; ++i)
                {
                    if (pCurrent->staticFuncs.entries[i])
                    {
                        sol::table f = lua.create_table();
                        f["name"] = pCurrent->staticFuncs.entries[i]->fullName.ToString();
                        f["shortName"] = pCurrent->staticFuncs.entries[i]->shortName.ToString();
                        f["fromClass"] = pCurrent->name.ToString();
                        f["isStatic"] = true;
                        funcs[funcIdx] = f;
                        funcIdx++;
                    }
                }
                pCurrent = pCurrent->parent;
            }

            result["functions"] = funcs;
            result["totalFuncs"] = funcIdx;

            return result;
        });

    // ============================================================
    // DumpAllQuestTypes - Find every RTTI type related to quests
    // Usage: local types = DumpAllQuestTypes()
    // ============================================================
    globals.set_function(
        "DumpAllQuestTypes",
        [](sol::this_state aState) -> sol::object
        {
            sol::state_view lua(aState);
            sol::table result = lua.create_table();
            int count = 0;

            RED4ext::CRTTISystem* pRtti = RED4ext::CRTTISystem::Get();
            if (!pRtti)
                return sol::nil;

            pRtti->types.for_each(
                [&](RED4ext::CName aName, RED4ext::CBaseRTTIType* apType)
                {
                    std::string nameStr = aName.ToString();
                    if (nameStr.find("quest") != std::string::npos || nameStr.find("Quest") != std::string::npos || nameStr.find("Phase") != std::string::npos ||
                        nameStr.find("phase") != std::string::npos)
                    {
                        sol::table entry = lua.create_table();
                        entry["name"] = nameStr;
                        entry["size"] = apType->GetSize();
                        entry["type"] = static_cast<int>(apType->GetType());
                        result[count] = entry;
                        count++;
                    }
                });

            return result;
        });

    // ============================================================
    // ReadNativeBytes - Read raw memory from a game object
    // Usage: local bytes = ReadNativeBytes(gameObj, offset, count)
    // Returns a Lua table of byte values {[1]=0xFF, [2]=0x00, ...}
    // ============================================================
    globals.set_function(
        "ReadNativeBytes",
        [](sol::this_state aState, sol::object aObj, int aOffset, int aCount) -> sol::object
        {
            sol::state_view lua(aState);

            if (aOffset < 0 || aCount <= 0 || aCount > 8192)
                return sol::nil;

            RED4ext::IScriptable* pObject = nullptr;

            if (aObj.is<StrongReference>())
            {
                StrongReference* pRef = aObj.as<StrongReference*>();
                pObject = static_cast<RED4ext::IScriptable*>(pRef->GetHandle());
            }
            else if (aObj.is<WeakReference>())
            {
                WeakReference* pRef = aObj.as<WeakReference*>();
                pObject = static_cast<RED4ext::IScriptable*>(pRef->GetHandle());
            }

            if (!pObject)
                return sol::nil;

            sol::table result = lua.create_table();
            uint8_t* basePtr = reinterpret_cast<uint8_t*>(pObject);

            for (int i = 0; i < aCount; i++)
            {
                result[i + 1] = static_cast<int>(basePtr[aOffset + i]);
            }

            return result;
        });

    // ============================================================
    // WriteNativeBytes - Write raw memory to a game object
    // Usage: WriteNativeBytes(gameObj, offset, {0xFF, 0x00, 0x01})
    // USE WITH EXTREME CAUTION - can crash the game
    // ============================================================
    globals.set_function(
        "WriteNativeBytes",
        [](sol::object aObj, int aOffset, sol::table aBytes) -> bool
        {
            if (aOffset < 0)
                return false;

            RED4ext::IScriptable* pObject = nullptr;

            if (aObj.is<StrongReference>())
            {
                StrongReference* pRef = aObj.as<StrongReference*>();
                pObject = static_cast<RED4ext::IScriptable*>(pRef->GetHandle());
            }
            else if (aObj.is<WeakReference>())
            {
                WeakReference* pRef = aObj.as<WeakReference*>();
                pObject = static_cast<RED4ext::IScriptable*>(pRef->GetHandle());
            }

            if (!pObject)
                return false;

            uint8_t* basePtr = reinterpret_cast<uint8_t*>(pObject);

            for (int i = 1; i <= static_cast<int>(aBytes.size()); i++)
            {
                sol::object val = aBytes[i];
                if (val.is<int>())
                {
                    basePtr[aOffset + i - 1] = static_cast<uint8_t>(val.as<int>());
                }
            }

            return true;
        });

    // ============================================================
    // DumpToFile - Write a string to a file in the CET directory
    // Usage: DumpToFile("quest_dump.json", jsonString)
    // ============================================================
    globals.set_function(
        "DumpToFile",
        [](const std::string& acFilename, const std::string& acContent) -> bool
        {
            std::ofstream ofs(acFilename);
            if (!ofs.is_open())
                return false;
            ofs << acContent;
            ofs.close();
            return true;
        });

    // ============================================================
    // END OF REPLACEMENT BLOCK
    // ============================================================

    globals["IsDefined"] = sol::overload(
        // Check if weak reference is still valid
        [](const WeakReference& aRef) -> bool { return !aRef.m_weakHandle.Expired(); },
        // To make it callable for strong reference
        // although it's always valid unless it's null
        [](const StrongReference&) -> bool { return true; },
        // To make it callable on any value
        [](const sol::object&) -> bool { return false; });

    globals.new_usertype<Enum>(
        "Enum", sol::constructors<Enum(const std::string&, const std::string&), Enum(const std::string&, uint32_t), Enum(const Enum&)>(), sol::meta_function::to_string,
        &Enum::ToString, sol::meta_function::equal_to, &Enum::operator==, "value", sol::property(&Enum::GetValueName, &Enum::SetValueByName));

    globals["EnumInt"] = [this](Enum& aEnum) -> sol::object
    {
        static RTTILocator s_uint64Type{RED4ext::FNV1a64("Uint64")};

        auto lockedState = m_lua.Lock();

        RED4ext::CStackType stackType;
        stackType.type = s_uint64Type;
        stackType.value = &aEnum.m_value;

        return Converter::ToLua(stackType, lockedState);
    };

    luaVm.new_usertype<Vector3>(
        "Vector3", sol::constructors<Vector3(float, float, float), Vector3(float, float), Vector3(float), Vector3(const Vector3&), Vector3()>(), sol::meta_function::to_string,
        &Vector3::ToString, sol::meta_function::equal_to, &Vector3::operator==, "x", &Vector3::x, "y", &Vector3::y, "z", &Vector3::z);
    globals["Vector3"] = luaVm["Vector3"];

    globals["ToVector3"] = [](sol::table table) -> Vector3
    {
        return Vector3{table["x"].get_or(0.f), table["y"].get_or(0.f), table["z"].get_or(0.f)};
    };

    luaVm.new_usertype<Vector4>(
        "Vector4",
        sol::constructors<Vector4(float, float, float, float), Vector4(float, float, float), Vector4(float, float), Vector4(float), Vector4(const Vector4&), Vector4()>(),
        sol::meta_function::to_string, &Vector4::ToString, sol::meta_function::equal_to, &Vector4::operator==, "x", &Vector4::x, "y", &Vector4::y, "z", &Vector4::z, "w",
        &Vector4::w);
    globals["Vector4"] = luaVm["Vector4"];

    globals["ToVector4"] = [](sol::table table) -> Vector4
    {
        return Vector4{table["x"].get_or(0.f), table["y"].get_or(0.f), table["z"].get_or(0.f), table["w"].get_or(0.f)};
    };

    luaVm.new_usertype<EulerAngles>(
        "EulerAngles", sol::constructors<EulerAngles(float, float, float), EulerAngles(float, float), EulerAngles(float), EulerAngles(const EulerAngles&), EulerAngles()>(),
        sol::meta_function::to_string, &EulerAngles::ToString, sol::meta_function::equal_to, &EulerAngles::operator==, "roll", &EulerAngles::roll, "pitch", &EulerAngles::pitch,
        "yaw", &EulerAngles::yaw);
    globals["EulerAngles"] = luaVm["EulerAngles"];

    globals["ToEulerAngles"] = [](sol::table table) -> EulerAngles
    {
        return EulerAngles{table["roll"].get_or(0.f), table["pitch"].get_or(0.f), table["yaw"].get_or(0.f)};
    };

    luaVm.new_usertype<Quaternion>(
        "Quaternion",
        sol::constructors<
            Quaternion(float, float, float, float), Quaternion(float, float, float), Quaternion(float, float), Quaternion(float), Quaternion(const Quaternion&), Quaternion()>(),
        sol::meta_function::to_string, &Quaternion::ToString, sol::meta_function::equal_to, &Quaternion::operator==, "i", &Quaternion::i, "j", &Quaternion::j, "k", &Quaternion::k,
        "r", &Quaternion::r);
    globals["Quaternion"] = luaVm["Quaternion"];

    globals["ToQuaternion"] = [](sol::table table) -> Quaternion
    {
        return Quaternion{table["i"].get_or(0.f), table["j"].get_or(0.f), table["k"].get_or(0.f), table["r"].get_or(0.f)};
    };

    globals.new_usertype<CName>(
        "CName", sol::constructors<CName(const std::string&), CName(uint64_t), CName(uint32_t, uint32_t), CName(const CName&), CName()>(), sol::call_constructor,
        sol::constructors<CName(const std::string&), CName(uint64_t)>(), sol::meta_function::to_string, &CName::ToString, sol::meta_function::equal_to, &CName::operator==,
        "hash_lo", &CName::hash_lo, "hash_hi", &CName::hash_hi, "value", sol::property(&CName::AsString), "add", &CName::Add);

    globals["ToCName"] = [](sol::table table) -> CName
    {
        return CName{table["hash_lo"].get_or<uint32_t>(0), table["hash_hi"].get_or<uint32_t>(0)};
    };

    globals.new_usertype<TweakDBID>(
        "TweakDBID",
        sol::constructors<TweakDBID(const std::string&), TweakDBID(const TweakDBID&, const std::string&), TweakDBID(uint32_t, uint8_t), TweakDBID(const TweakDBID&), TweakDBID()>(),
        sol::call_constructor, sol::constructors<TweakDBID(const std::string&)>(), sol::meta_function::to_string, &TweakDBID::ToString, sol::meta_function::equal_to,
        &TweakDBID::operator==, sol::meta_function::addition, &TweakDBID::operator+, sol::meta_function::concatenation, &TweakDBID::operator+, "hash", &TweakDBID::name_hash,
        "length", &TweakDBID::name_length, "value", sol::property(&TweakDBID::AsString));

    globals["ToTweakDBID"] = [](sol::table table) -> TweakDBID
    {
        // try with name first
        const auto name = table["name"].get_or<std::string>("");
        if (!name.empty())
            return TweakDBID(name);

        // if conversion from name failed, look for old hash + length
        return TweakDBID{table["hash"].get_or<uint32_t>(0), table["length"].get_or<uint8_t>(0)};
    };

    luaVm.new_usertype<ItemID>(
        "ItemID",
        sol::constructors<
            ItemID(const TweakDBID&, uint32_t, uint16_t, uint8_t), ItemID(const TweakDBID&, uint32_t, uint16_t), ItemID(const TweakDBID&, uint32_t), ItemID(const TweakDBID&),
            ItemID(const ItemID&), ItemID()>(),
        sol::meta_function::to_string, &ItemID::ToString, sol::meta_function::equal_to, &ItemID::operator==, "id", &ItemID::id, "tdbid", &ItemID::id, "rng_seed", &ItemID::rng_seed,
        "unknown", &ItemID::unknown, "maybe_type", &ItemID::maybe_type);
    globals["ItemID"] = luaVm["ItemID"];

    globals["ToItemID"] = [](sol::table table) -> ItemID
    {
        return ItemID{
            table["id"].get_or<TweakDBID>(0),
            table["rng_seed"].get_or<uint32_t>(2),
            table["unknown"].get_or<uint16_t>(0),
            table["maybe_type"].get_or<uint8_t>(0),
        };
    };

    globals.new_usertype<CRUID>(
        "CRUID", sol::constructors<CRUID(uint64_t)>(), sol::call_constructor, sol::constructors<CRUID(uint64_t)>(), sol::meta_function::to_string, &CRUID::ToString,
        sol::meta_function::equal_to, &CRUID::operator==, "hash", &CRUID::hash);

    globals.new_usertype<gamedataLocKeyWrapper>(
        "LocKey", sol::constructors<gamedataLocKeyWrapper(uint64_t)>(), sol::meta_function::to_string, &gamedataLocKeyWrapper::ToString, sol::meta_function::equal_to,
        &gamedataLocKeyWrapper::operator==, sol::call_constructor,
        sol::factories(
            [](sol::object aValue, sol::this_state aState) -> sol::object
            {
                sol::state_view lua(aState);
                gamedataLocKeyWrapper result(0);

                if (aValue != sol::nil)
                {
                    if (aValue.get_type() == sol::type::number)
                    {
                        result.hash = aValue.as<uint64_t>();
                    }
                    else if (IsLuaCData(aValue))
                    {
                        const std::string str = lua["tostring"](aValue);
                        result.hash = std::stoull(str);
                    }
                    else if (aValue.get_type() == sol::type::string)
                    {
                        result.hash = RED4ext::FNV1a64(aValue.as<const char*>());
                    }
                }

                return sol::object(lua, sol::in_place, std::move(result));
            }),
        "hash",
        sol::property(
            [](gamedataLocKeyWrapper& aThis, sol::this_state aState) -> sol::object
            {
                sol::state_view lua(aState);
                const auto converted = lua.script(fmt::format("return {}ull", aThis.hash));
                return converted.get<sol::object>();
            }));

    globals.new_usertype<GameOptions>(
        "GameOptions", sol::meta_function::construct, sol::no_constructor, "Print", &GameOptions::Print, "Get", &GameOptions::Get, "GetBool", &GameOptions::GetBool, "GetInt",
        &GameOptions::GetInt, "GetFloat", &GameOptions::GetFloat, "Set", &GameOptions::Set, "SetBool", &GameOptions::SetBool, "SetInt", &GameOptions::SetInt, "SetFloat",
        &GameOptions::SetFloat, "Toggle", &GameOptions::Toggle, "Dump", &GameOptions::Dump, "List", &GameOptions::List);

    globals["Override"] = [this](const std::string& acTypeName, const std::string& acFullName, sol::protected_function aFunction, sol::this_environment aThisEnv) -> void
    {
        m_override.Override(acTypeName, acFullName, aFunction, aThisEnv, true);
    };

    globals["ObserveBefore"] = [this](const std::string& acTypeName, const std::string& acFullName, sol::protected_function aFunction, sol::this_environment aThisEnv) -> void
    {
        m_override.Override(acTypeName, acFullName, aFunction, aThisEnv, false, false);
    };

    globals["ObserveAfter"] = [this](const std::string& acTypeName, const std::string& acFullName, sol::protected_function aFunction, sol::this_environment aThisEnv) -> void
    {
        m_override.Override(acTypeName, acFullName, aFunction, aThisEnv, false, true);
    };

    globals["Observe"] = globals["ObserveBefore"];

    globals.new_usertype<NativeProxy>("NativeProxy",
        sol::meta_function::construct, sol::no_constructor,
        "Target", &NativeProxy::GetTarget,
        "Function", sol::overload(&NativeProxy::GetFunction, &NativeProxy::GetDefaultFunction));

    globals["NewProxy"] = sol::overload(
        [this](const sol::object& aSpec, sol::this_state aState, sol::this_environment aEnv) -> sol::object
        {
            auto locledState = m_lua.Lock();
            return {aState, sol::in_place, NativeProxy(m_lua.AsRef(), aEnv, aSpec)};
        },
        [this](const std::string& aInterface, const sol::object& aSpec, sol::this_state aState,
               sol::this_environment aEnv) -> sol::object
        {
            auto locledState = m_lua.Lock();
            return {aState, sol::in_place, NativeProxy(m_lua.AsRef(), aEnv, aInterface, aSpec)};
        });

    globals["NewObject"] = [this](const std::string& acName, sol::this_environment aEnv) -> sol::object
    {
        auto* pRtti = RED4ext::CRTTISystem::Get();
        auto* pType = pRtti->GetType(RED4ext::FNV1a64(acName.c_str()));

        if (!pType)
        {
            const sol::environment cEnv = aEnv;
            const auto logger = cEnv["__logger"].get<std::shared_ptr<spdlog::logger>>();
            logger->info("Type '{}' not found.", acName);
            return sol::nil;
        }

        // Always try to return instance wrapped in Handle<> if the type allows it.
        // See NewHandle() for more info.
        return RTTIHelper::Get().NewHandle(pType, sol::nullopt);
    };

    globals["GetSingleton"] = [this](const std::string& acName, sol::this_environment aThisEnv)
    {
        return this->GetSingletonHandle(acName, aThisEnv);
    };

    globals["GetMod"] = [this](const std::string& acName) -> sol::object
    {
        return GetMod(acName);
    };

    globals["GameDump"] = [this](const Type* acpType)
    {
        return acpType ? acpType->GameDump() : "Null";
    };

    globals["Dump"] = [this](const Type* acpType, bool aDetailed)
    {
        return acpType != nullptr ? acpType->Dump(aDetailed) : Type::Descriptor{};
    };

    globals["DumpType"] = [this](const std::string& acName, bool aDetailed)
    {
        auto* pRtti = RED4ext::CRTTISystem::Get();
        auto* pType = pRtti->GetClass(RED4ext::FNV1a64(acName.c_str()));
        if (!pType || pType->GetType() == RED4ext::ERTTIType::Simple)
            return Type::Descriptor();

        const ClassType type(m_lua.AsRef(), pType);
        return type.Dump(aDetailed);
    };

    globals["DumpAllTypeNames"] = [this](sol::this_environment aThisEnv)
    {
        const auto* pRtti = RED4ext::CRTTISystem::Get();

        uint32_t count = 0;
        pRtti->types.for_each(
            [&count](RED4ext::CName name, RED4ext::CBaseRTTIType*&)
            {
                Log::Info(name.ToString());
                count++;
            });
        const sol::environment cEnv = aThisEnv;
        const auto logger = cEnv["__logger"].get<std::shared_ptr<spdlog::logger>>();
        logger->info("Dumped {} types", count);
    };

#ifdef CET_DEBUG
    globals["DumpVtables"] = [this]
    {
        // Hacky RTTI dump, this should technically only dump IScriptable instances and RTTI types as they are
        // guaranteed to have a vtable but there can occasionally be Class types that are not IScriptable derived that
        // still have a vtable some hierarchies may also not be accurately reflected due to hash ordering technically
        // this table is flattened and contains all hierarchy, but traversing the hierarchy first reduces error when
        // there are classes that instantiate a parent class but don't actually have a subclass instance
        GameMainThread::Get().AddRunningTask(&GameDump::DumpVTablesTask::Run);
    };
#endif

    globals["Game"] = this;

    RTTIHelper::Initialize(m_lua.AsRef(), m_sandbox);
    RTTIExtender::InitializeTypes();

    m_mapper.Register();

    m_sandbox.PostInitializeScripting();
    m_sandbox.PostInitializeMods();

    TriggerOnHook();
}

void Scripting::PostInitializeTweakDB()
{
    auto lua = m_lua.Lock();
    auto& luaVm = lua.Get();
    auto& globals = m_sandbox.GetGlobals();

    luaVm.new_usertype<TweakDB>(
        "__TweakDB", sol::meta_function::construct, sol::no_constructor, "DebugStats", &TweakDB::DebugStats, "GetRecords", &TweakDB::GetRecords, "GetRecord",
        overload(&TweakDB::GetRecordByName, &TweakDB::GetRecord), "Query", overload(&TweakDB::QueryByName, &TweakDB::Query), "GetFlat",
        overload(&TweakDB::GetFlatByName, &TweakDB::GetFlat), "SetFlats", overload(&TweakDB::SetFlatsByName, &TweakDB::SetFlats), "SetFlat",
        overload(&TweakDB::SetTypedFlat, &TweakDB::SetTypedFlatByName, &TweakDB::SetFlatByNameAutoUpdate, &TweakDB::SetFlatAutoUpdate), "SetFlatNoUpdate",
        overload(&TweakDB::SetFlatByName, &TweakDB::SetFlat), "Update", overload(&TweakDB::UpdateRecordByName, &TweakDB::UpdateRecordByID, &TweakDB::UpdateRecord), "CreateRecord",
        overload(&TweakDB::CreateRecordToID, &TweakDB::CreateRecord), "CloneRecord", overload(&TweakDB::CloneRecordByName, &TweakDB::CloneRecordToID, &TweakDB::CloneRecord),
        "DeleteRecord", overload(&TweakDB::DeleteRecordByID, &TweakDB::DeleteRecord));

    globals["TweakDB"] = TweakDB(m_lua.AsRef());

    m_sandbox.PostInitializeTweakDB();

    // Due to how TweakDB modifications are implemented in CET, some REDengine functions may attempt to allocate
    // new data in the buffer. But these functions don't resize the buffer, so they can get out of bounds and crash.
    // This edge case can be fixed by resizing TweakDB flat buffer to max capacity beforehand.
    RED4ext::TweakDB::Get()->UpsizeFlatDataBufferToMax();

    TriggerOnTweak();
}

void Scripting::PostInitializeMods()
{
    auto lua = m_lua.Lock();
    auto& luaVm = lua.Get();

    RTTIExtender::InitializeSingletons();

    RegisterOverrides();

    TriggerOnInit();
    if (CET::Get().GetOverlay().IsEnabled())
        TriggerOnOverlayOpen();
}

void Scripting::RegisterOverrides()
{
    auto lua = m_lua.Lock();
    auto& luaVm = lua.Get();

    luaVm["RegisterGlobalInputListener"] = [](WeakReference& aSelf, sol::this_environment aThisEnv)
    {
        const sol::protected_function unregisterInputListener = aSelf.Index("UnregisterInputListener", aThisEnv);
        const sol::protected_function registerInputListener = aSelf.Index("RegisterInputListener", aThisEnv);

        unregisterInputListener(aSelf, aSelf);
        registerInputListener(aSelf, aSelf);
    };

    m_override.Override("PlayerPuppet", "GracePeriodAfterSpawn", luaVm["RegisterGlobalInputListener"], sol::nil, false, false, true);
    m_override.Override("PlayerPuppet", "OnDetach", sol::nil, sol::nil, false, false, true);
    m_override.Override("QuestTrackerGameController", "OnUninitialize", sol::nil, sol::nil, false, false, true);
}

const VKBind* Scripting::GetBind(const VKModBind& acModBind) const
{
    return m_store.GetBind(acModBind);
}

const TiltedPhoques::Vector<VKBind>* Scripting::GetBinds(const std::string& acModName) const
{
    return m_store.GetBinds(acModName);
}

const TiltedPhoques::Map<std::string, std::reference_wrapper<const TiltedPhoques::Vector<VKBind>>>& Scripting::GetAllBinds() const
{
    return m_store.GetAllBinds();
}

void Scripting::TriggerOnHook() const
{
    m_store.TriggerOnHook();
}

void Scripting::TriggerOnTweak() const
{
    m_store.TriggerOnTweak();
}

void Scripting::TriggerOnInit() const
{
    m_store.TriggerOnInit();
}

void Scripting::TriggerOnUpdate(float aDeltaTime) const
{
    m_store.TriggerOnUpdate(aDeltaTime);
}

void Scripting::TriggerOnDraw() const
{
    m_store.TriggerOnDraw();
}

void Scripting::TriggerOnOverlayOpen() const
{
    m_store.TriggerOnOverlayOpen();
}

void Scripting::TriggerOnOverlayClose() const
{
    m_store.TriggerOnOverlayClose();
}

sol::object Scripting::GetMod(const std::string& acName) const
{
    return m_store.GetMod(acName);
}

void Scripting::UnloadAllMods()
{
    m_override.Clear();
    RegisterOverrides();
    m_store.DiscardAll();
}

void Scripting::ReloadAllMods()
{
    UnloadAllMods();

    m_store.LoadAll();

    TriggerOnHook();
    TriggerOnTweak();
    TriggerOnInit();

    if (CET::Get().GetOverlay().IsEnabled())
        TriggerOnOverlayOpen();

    spdlog::get("scripting")->info("LuaVM: Reloaded all mods!");
}

bool Scripting::ExecuteLua(const std::string& acCommand) const
{
    // TODO: proper exception handling!
    try
    {
        auto lockedState = m_lua.Lock();
        const auto cResult = m_sandbox[0].ExecuteString(acCommand);
        if (cResult.valid())
            return true;
        const sol::error cError = cResult;
        spdlog::get("scripting")->error(cError.what());
    }
    catch (std::exception& e)
    {
        spdlog::get("scripting")->error(e.what());
    }
    return false;
}

void Scripting::CollectGarbage() const
{
    auto lockedState = m_lua.Lock();
    auto& luaState = lockedState.Get();

    luaState.collect_garbage();
}

LuaSandbox& Scripting::GetSandbox()
{
    return m_sandbox;
}

Scripting::LockedState Scripting::GetLockedState() const noexcept
{
    return m_lua.Lock();
}

sol::object Scripting::Index(const std::string& acName, sol::this_state aState, sol::this_environment aEnv)
{
    if (const auto itor = m_properties.find(acName); itor != m_properties.end())
    {
        return itor->second;
    }

    const auto func = RTTIHelper::Get().ResolveFunction(acName);

    if (!func)
    {
        std::string errorMessage = fmt::format("Function {} is not a GameInstance member and is not a global.", acName);

        if constexpr (s_cThrowLuaErrors)
        {
            luaL_error(aState, errorMessage.c_str());
        }
        else
        {
            const sol::environment cEnv = aEnv;
            auto logger = cEnv["__logger"].get<std::shared_ptr<spdlog::logger>>();
            logger->error("Error: {}", errorMessage);
        }

        return sol::nil;
    }

    auto& property = m_properties[acName];
    property = func;
    return property;
}

sol::object Scripting::GetSingletonHandle(const std::string& acName, sol::this_environment aThisEnv)
{
    auto lockedState = m_lua.Lock();
    const auto& luaState = lockedState.Get();

    const auto itor = m_singletons.find(acName);
    if (itor != std::end(m_singletons))
        return make_object(luaState, itor->second);

    auto* pRtti = RED4ext::CRTTISystem::Get();
    auto* pType = pRtti->GetClass(RED4ext::FNV1a64(acName.c_str()));
    if (!pType)
    {
        const sol::environment cEnv = aThisEnv;
        const auto logger = cEnv["__logger"].get<std::shared_ptr<spdlog::logger>>();
        logger->info("Type '{}' not found.", acName);
        return sol::nil;
    }

    const auto result = m_singletons.emplace(std::make_pair(acName, SingletonReference{m_lua.AsRef(), pType}));
    return make_object(luaState, result.first->second);
}

size_t Scripting::Size(RED4ext::CBaseRTTIType* apRttiType)
{
    if (apRttiType == s_stringType)
        return sizeof(RED4ext::CString);
    if (apRttiType->GetType() == RED4ext::ERTTIType::Handle)
        return sizeof(RED4ext::Handle<RED4ext::IScriptable>);
    if (apRttiType->GetType() == RED4ext::ERTTIType::WeakHandle)
        return sizeof(RED4ext::WeakHandle<RED4ext::IScriptable>);

    return Converter::Size(apRttiType);
}

sol::object Scripting::ToLua(LockedState& aState, RED4ext::CStackType& aResult)
{
    auto* pType = aResult.type;

    const auto& state = aState.Get();

    if (pType == nullptr)
        return sol::nil;
    if (pType == s_stringType)
        return make_object(state, std::string(static_cast<RED4ext::CString*>(aResult.value)->c_str()));
    if (pType->GetType() == RED4ext::ERTTIType::Handle)
    {
        const auto handle = *static_cast<RED4ext::Handle<RED4ext::IScriptable>*>(aResult.value);
        if (handle)
            return make_object(state, StrongReference(aState, handle, static_cast<RED4ext::CRTTIHandleType*>(pType)));
    }
    else if (pType->GetType() == RED4ext::ERTTIType::WeakHandle)
    {
        const auto handle = *static_cast<RED4ext::WeakHandle<RED4ext::IScriptable>*>(aResult.value);
        if (!handle.Expired())
            return make_object(state, WeakReference(aState, handle, static_cast<RED4ext::CRTTIWeakHandleType*>(pType)));
    }
    else if (pType->GetType() == RED4ext::ERTTIType::Array)
    {
        const auto* pArrayType = static_cast<RED4ext::CRTTIArrayType*>(pType);
        const uint32_t cLength = pArrayType->GetLength(aResult.value);
        sol::table result(state, sol::create);
        for (auto i = 0u; i < cLength; ++i)
        {
            RED4ext::CStackType el;
            el.value = pArrayType->GetElement(aResult.value, i);
            el.type = pArrayType->GetInnerType();

            result[i + 1] = ToLua(aState, el);
        }

        return result;
    }
    else if (pType->GetType() == RED4ext::ERTTIType::ResourceAsyncReference)
    {
        auto* pInstance = static_cast<RED4ext::ResourceAsyncReference<void>*>(aResult.value);
        if (pInstance)
            return make_object(state, ResourceAsyncReference(aState, aResult.type, pInstance));
    }
    else if (pType->GetType() == RED4ext::ERTTIType::ScriptReference)
    {
        const auto* pInstance = static_cast<RED4ext::ScriptRef<void>*>(aResult.value);
        RED4ext::CStackType innerStack;
        innerStack.value = pInstance->ref;
        innerStack.type = pInstance->innerType;
        return ToLua(aState, innerStack);
    }
    else
    {
        auto result = Converter::ToLua(aResult, aState);
        if (result != sol::nil)
            return result;
    }

    return sol::nil;
}

RED4ext::CStackType Scripting::ToRED(sol::object aObject, RED4ext::CBaseRTTIType* apRttiType, TiltedPhoques::Allocator* apAllocator)
{
    RED4ext::CStackType result;

    const bool hasData = aObject != sol::nil;

    if (apRttiType)
    {
        result.type = apRttiType;

        if (apRttiType == s_stringType)
        {
            std::string str;
            if (hasData)
            {
                sol::state_view v(aObject.lua_state());
                str = v["tostring"](aObject).get<std::string>();
            }
            result.value = apAllocator->New<RED4ext::CString>(str.c_str());
        }
        else if (apRttiType->GetType() == RED4ext::ERTTIType::Handle)
        {
            if (aObject.is<StrongReference>())
            {
                const auto* pSubType = static_cast<RED4ext::CClass*>(apRttiType)->parent;
                const auto* pType = static_cast<RED4ext::CClass*>(aObject.as<StrongReference*>()->m_pType);
                if (pType && pType->IsA(pSubType))
                {
                    result.value = apAllocator->New<RED4ext::Handle<RED4ext::IScriptable>>(aObject.as<StrongReference>().m_strongHandle);
                }
            }
            else if (aObject.is<WeakReference>())
            {
                const auto* pSubType = static_cast<RED4ext::CClass*>(apRttiType)->parent;
                const auto* pType = static_cast<RED4ext::CClass*>(aObject.as<WeakReference*>()->m_pType);
                if (pType && pType->IsA(pSubType))
                {
                    result.value = apAllocator->New<RED4ext::Handle<RED4ext::IScriptable>>(aObject.as<WeakReference>().m_weakHandle);
                }
            }
            else if (!hasData)
            {
                result.value = apAllocator->New<RED4ext::Handle<RED4ext::IScriptable>>();
            }
        }
        else if (apRttiType->GetType() == RED4ext::ERTTIType::WeakHandle)
        {
            if (aObject.is<WeakReference>())
            {
                const auto* pSubType = static_cast<RED4ext::CClass*>(apRttiType)->parent;
                const auto* pType = static_cast<RED4ext::CClass*>(aObject.as<WeakReference*>()->m_pType);
                if (pType && pType->IsA(pSubType))
                {
                    result.value = apAllocator->New<RED4ext::WeakHandle<RED4ext::IScriptable>>(aObject.as<WeakReference>().m_weakHandle);
                }
            }
            else if (aObject.is<StrongReference>()) // Handle Implicit Cast
            {
                const auto* pSubType = static_cast<RED4ext::CClass*>(apRttiType)->parent;
                const auto* pType = static_cast<RED4ext::CClass*>(aObject.as<StrongReference*>()->m_pType);
                if (pType && pType->IsA(pSubType))
                {
                    result.value = apAllocator->New<RED4ext::WeakHandle<RED4ext::IScriptable>>(aObject.as<StrongReference>().m_strongHandle);
                }
            }
            else if (!hasData)
            {
                result.value = apAllocator->New<RED4ext::WeakHandle<RED4ext::IScriptable>>();
            }
        }
        else if (apRttiType->GetType() == RED4ext::ERTTIType::Array)
        {
            if (!hasData || aObject.get_type() == sol::type::table)
            {
                auto* pArrayType = static_cast<RED4ext::CRTTIArrayType*>(apRttiType);
                auto pMemory = static_cast<RED4ext::DynArray<void*>*>(apAllocator->Allocate(apRttiType->GetSize()));
                apRttiType->Construct(pMemory);

                if (hasData)
                {
                    const auto tbl = aObject.as<sol::table>();

                    if (tbl.size() > 0)
                    {
                        auto* pArrayInnerType = pArrayType->GetInnerType();

                        // Copy elements from the table into the array
                        pArrayType->Resize(pMemory, static_cast<uint32_t>(tbl.size()));
                        for (uint32_t i = 1; i <= tbl.size(); ++i)
                        {
                            RED4ext::CStackType data = ToRED(tbl.get<sol::object>(i), pArrayInnerType, apAllocator);

                            // Break on first incompatible element
                            if (!data.value)
                            {
                                pArrayType->Destruct(pMemory);
                                pMemory = nullptr;
                                break;
                            }

                            const auto pElement = pArrayType->GetElement(pMemory, i - 1);
                            pArrayInnerType->Assign(pElement, data.value);

                            DestructRED(data, false);
                        }
                    }
                }

                result.value = pMemory;
            }
        }
        else if (apRttiType->GetType() == RED4ext::ERTTIType::ScriptReference)
        {
            if (hasData)
            {
                auto* pInnerType = static_cast<RED4ext::CRTTIScriptReferenceType*>(apRttiType)->innerType;
                const RED4ext::CStackType innerValue = ToRED(aObject, pInnerType, apAllocator);

                if (innerValue.value)
                {
                    auto* pScriptRef = apAllocator->New<RED4ext::ScriptRef<void>>();
                    pScriptRef->innerType = innerValue.type;
                    pScriptRef->ref = innerValue.value;
                    pScriptRef->hash = apRttiType->GetName();
                    result.value = pScriptRef;
                }
            }
        }
        else if (apRttiType->GetType() == RED4ext::ERTTIType::ResourceAsyncReference || apRttiType == s_resRefType)
        {
            if (hasData)
            {
                uint64_t hash = 0;
                bool valid = false;

                if (aObject.is<ResourceAsyncReference>())
                {
                    hash = aObject.as<ResourceAsyncReference*>()->GetHash();
                    valid = true;
                }
                else if (aObject.get_type() == sol::type::string)
                {
                    hash = ResourceAsyncReference::Hash(aObject.as<std::string>());
                    valid = true;
                }
                else if (aObject.get_type() == sol::type::number)
                {
                    hash = aObject.as<uint64_t>();
                    valid = true;
                }
                else if (aObject.is<CName>())
                {
                    hash = aObject.as<CName*>()->hash;
                    valid = true;
                }
                else if (aObject.is<ClassReference>())
                {
                    auto& ref = aObject.as<ClassReference>();
                    if (ref.GetType() == s_resRefType)
                    {
                        hash = *reinterpret_cast<uint64_t*>(ref.GetValuePtr());
                        valid = true;
                    }
                }
                else if (IsLuaCData(aObject))
                {
                    sol::state_view v(aObject.lua_state());
                    const std::string str = v["tostring"](aObject);
                    hash = std::stoull(str);
                    valid = true;
                }

                if (valid)
                {
                    auto* pRaRef = apAllocator->New<RED4ext::ResourceAsyncReference<void>>();
                    pRaRef->path.hash = hash;

                    result.value = pRaRef;
                }
            }
        }
        else
        {
            return Converter::ToRED(aObject, apRttiType, apAllocator);
        }
    }

    return result;
}

void Scripting::ToRED(sol::object aObject, RED4ext::CStackType& aRet)
{
    static thread_local TiltedPhoques::ScratchAllocator s_scratchMemory(1 << 14);

    auto result = ToRED(aObject, aRet.type, &s_scratchMemory);
    aRet.type->Assign(aRet.value, result.value);
    DestructRED(result, false);

    s_scratchMemory.Reset();
}

void Scripting::DestructRED(const RED4ext::CStackType& aStackType, bool aOwned)
{
    if (!aStackType.value)
        return;

    if (aStackType.type->GetType() == RED4ext::ERTTIType::ScriptReference)
    {
        auto pRef = reinterpret_cast<RED4ext::ScriptRef<void>*>(aStackType.value);
        DestructRED({pRef->innerType, pRef->ref}, aOwned);
        return;
    }

    // Destroy only data created and owned by the caller,
    // and types that always produce a copy when converted from lua to RED.
    if (aOwned || IsConvertedByCopying(aStackType.type))
    {
        aStackType.type->Destruct(aStackType.value);
    }
}

bool Scripting::IsConvertedByCopying(RED4ext::CBaseRTTIType* aType)
{
    if (aType == s_stringType)
    {
        return true;
    }

    switch (aType->GetType())
    {
    case RED4ext::ERTTIType::Array:
    case RED4ext::ERTTIType::Handle:
    case RED4ext::ERTTIType::WeakHandle:
        return true;
    }

    return false;
}
