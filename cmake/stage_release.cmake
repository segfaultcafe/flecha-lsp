foreach(variable IN ITEMS
        EXECUTABLE SOURCE_ROOT OUTPUT_ROOT VERSION ARCHIVE_PLATFORM)
    if(NOT DEFINED ${variable} OR "${${variable}}" STREQUAL "")
        message(FATAL_ERROR "${variable} is required")
    endif()
endforeach()

if(NOT DEFINED EXECUTABLE_SUFFIX)
    set(EXECUTABLE_SUFFIX "")
endif()

if(NOT EXISTS "${EXECUTABLE}")
    message(FATAL_ERROR "Missing flecha-lsp executable: ${EXECUTABLE}")
endif()

set(bundleName "flecha-lsp-${VERSION}-${ARCHIVE_PLATFORM}")
set(bundleRoot "${OUTPUT_ROOT}/${bundleName}")
set(bundleBin "${bundleRoot}/bin")
set(bundleDocs "${bundleRoot}/share/doc/flecha-lsp")

file(REMOVE_RECURSE "${OUTPUT_ROOT}")
file(MAKE_DIRECTORY "${bundleBin}" "${bundleDocs}")
file(COPY_FILE
    "${EXECUTABLE}"
    "${bundleBin}/flecha-lsp${EXECUTABLE_SUFFIX}"
    ONLY_IF_DIFFERENT
)

foreach(document IN ITEMS README.md ARCHITECTURE.md CHANGELOG.md)
    file(COPY_FILE
        "${SOURCE_ROOT}/${document}"
        "${bundleDocs}/${document}"
        ONLY_IF_DIFFERENT
    )
endforeach()
file(COPY_FILE
    "${SOURCE_ROOT}/docs/editors.md"
    "${bundleDocs}/editors.md"
    ONLY_IF_DIFFERENT
)

set(runtimeDependencyFilters)
set(runtimeDependencyDirectories)
if(WIN32)
    list(APPEND runtimeDependencyFilters
        PRE_EXCLUDE_REGEXES
        "^api-ms-win-.*"
        "^ext-ms-win-.*"
        POST_EXCLUDE_REGEXES
        "[/\\\\][Ww][Ii][Nn][Dd][Oo][Ww][Ss][/\\\\]([Ss][Yy][Ss][Tt][Ee][Mm]32|[Ss][Yy][Ss][Ww][Oo][Ww]64)[/\\\\]"
    )
endif()
if(DEFINED RUNTIME_SEARCH_DIRECTORY AND
        NOT "${RUNTIME_SEARCH_DIRECTORY}" STREQUAL "")
    list(APPEND runtimeDependencyDirectories
        DIRECTORIES "${RUNTIME_SEARCH_DIRECTORY}"
    )
endif()

file(GET_RUNTIME_DEPENDENCIES
    EXECUTABLES "${EXECUTABLE}"
    RESOLVED_DEPENDENCIES_VAR resolvedDependencies
    UNRESOLVED_DEPENDENCIES_VAR unresolvedDependencies
    CONFLICTING_DEPENDENCIES_PREFIX dependencyConflicts
    ${runtimeDependencyFilters}
    ${runtimeDependencyDirectories}
)

if(unresolvedDependencies)
    list(JOIN unresolvedDependencies ", " unresolvedText)
    message(FATAL_ERROR "Unresolved runtime dependencies: ${unresolvedText}")
endif()
if(dependencyConflicts_FILENAMES)
    list(JOIN dependencyConflicts_FILENAMES ", " conflictText)
    message(FATAL_ERROR "Conflicting runtime dependencies: ${conflictText}")
endif()

foreach(dependency IN LISTS resolvedDependencies)
    get_filename_component(dependencyName "${dependency}" NAME)
    set(isSystemDependency FALSE)

    if(WIN32)
        file(TO_CMAKE_PATH "${dependency}" normalizedDependency)
        string(TOLOWER "${normalizedDependency}" normalizedDependency)
        if(normalizedDependency MATCHES "/windows/(system32|syswow64)/")
            set(isSystemDependency TRUE)
        endif()
    elseif(APPLE)
        if(dependency MATCHES "^(/System/Library/|/usr/lib/)")
            set(isSystemDependency TRUE)
        endif()
    else()
        if(dependencyName MATCHES
                "^(ld-linux|libc[.]so|libm[.]so|libdl[.]so|libpthread[.]so|librt[.]so|libgcc_s[.]so|libstdc[+][+]|libresolv[.]so|libutil[.]so)")
            set(isSystemDependency TRUE)
        endif()
    endif()

    if(NOT isSystemDependency)
        if(WIN32)
            file(COPY "${dependency}" DESTINATION "${bundleBin}")
        else()
            message(FATAL_ERROR
                "Non-system runtime dependency is not relocatable: ${dependency}"
            )
        endif()
    endif()
endforeach()

message(STATUS "Staged ${bundleName} in ${bundleRoot}")
