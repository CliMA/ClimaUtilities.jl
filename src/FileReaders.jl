"""
    FileReaders

The `FileReaders` module implements backends to read and process input files.

Given that reading from disk can be an expensive operation, this module provides a pathway
to optimize the performance (if needed).

The FileReaders module contains a global cache of all the NCDatasets that are currently open.
This allows multiple NCFileReader to share the underlying file without overhead.
"""
module FileReaders

abstract type AbstractFileReader end

function NCFileReader end

function read end

end
