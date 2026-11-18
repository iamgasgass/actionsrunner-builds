// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

#include "video_decoder.hpp"
#include "apple/h264_stream.hpp"
#include "apple/hevc_stream.hpp"

#include <cstdint>
#include <fstream>
#include <iterator>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

/* What the platform decoder tests share: the fixtures of tests/support/video,
 * and the pictures of a fixture stream as a V4L2 client queues them. */
namespace uml::testing::video_decoder {
using Bytes = std::vector<std::uint8_t>;

inline std::string fixtureDirectory;

inline std::vector<std::uint8_t> read(const std::string& name)
{
    const auto path = fixtureDirectory + "/" + name;
    std::ifstream file(path, std::ios::binary);
    if (!file) throw std::runtime_error("missing video fixture: " + path);
    return {std::istreambuf_iterator<char>(file), {}};
}

/* The pictures of an Annex B stream, one buffer each with the parameter sets
 * that precede it: what a V4L2 client queues. */
inline std::vector<Bytes> accessUnits(const Bytes& stream)
{
    namespace bitstream = uml::platform::bitstream;
    std::vector<Bytes> result;
    Bytes current;
    bool hasPicture = false;
    for (const auto unit : bitstream::splitAnnexB(stream)) {
        const bool picture = bitstream::hevcNalType(unit) < 32;
        const bool first = picture && unit.size() > 2 && (unit[2] & 0x80) != 0;
        if (hasPicture && (!picture || first)) {
            result.push_back(std::move(current));
            current.clear();
            hasPicture = false;
        }
        bitstream::appendAnnexB(current, unit.data(), unit.size());
        hasPicture = hasPicture || picture;
    }
    if (hasPicture) result.push_back(std::move(current));
    return result;
}

// The access unit without its VPS, SPS and PPS, as a client sends it after a seek.
inline Bytes withoutParameterSets(const Bytes& accessUnit)
{
    namespace bitstream = uml::platform::bitstream;
    Bytes result;
    for (const auto unit : bitstream::splitAnnexB(accessUnit)) {
        const auto type = bitstream::hevcNalType(unit);
        if (type < 32 || type > 34) bitstream::appendAnnexB(result, unit.data(), unit.size());
    }
    return result;
}

// The same for H.264: the pictures of an Annex B stream with the parameter sets that precede each.
inline std::vector<Bytes> h264AccessUnits(const Bytes& stream)
{
    namespace bitstream = uml::platform::bitstream;
    namespace h264 = uml::platform::h264;
    std::vector<Bytes> result;
    Bytes current;
    h264::ParameterSets sets;
    std::optional<h264::SliceHeader> last;
    bool hasPicture = false;
    for (const auto unit : bitstream::splitAnnexB(stream)) {
        const auto type = h264::nalType(unit);
        bool starts = false;
        if (type == h264::nalSps || type == h264::nalPps) {
            sets.store(unit);
            starts = true;
        } else if (h264::isPicture(type)) {
            const auto header = h264::parseSliceHeader(unit, sets);
            if (!header) throw std::runtime_error("H.264 fixture has a slice without its parameter sets");
            starts = last && h264::startsPicture(*last, *header);
            last = header;
        } else {
            starts = true;
        }
        if (hasPicture && starts) {
            result.push_back(std::move(current));
            current.clear();
            hasPicture = false;
        }
        bitstream::appendAnnexB(current, unit.data(), unit.size());
        hasPicture = hasPicture || h264::isPicture(type);
    }
    if (hasPicture) result.push_back(std::move(current));
    return result;
}

inline Bytes withoutH264ParameterSets(const Bytes& accessUnit)
{
    namespace bitstream = uml::platform::bitstream;
    namespace h264 = uml::platform::h264;
    Bytes result;
    for (const auto unit : bitstream::splitAnnexB(accessUnit)) {
        const auto type = h264::nalType(unit);
        if (type != h264::nalSps && type != h264::nalPps) bitstream::appendAnnexB(result, unit.data(), unit.size());
    }
    return result;
}

inline double meanLuma(const uml::platform::DecodedVideoFrame& frame)
{
    std::uint64_t sum = 0;
    const std::size_t step = frame.format.bitDepth == 10 ? 2 : 1;
    std::size_t count = 0;
    for (std::size_t i = step - 1; i < frame.luma.size(); i += step, ++count) sum += frame.luma[i];
    return count ? double(sum) / double(count) : 0.0;
}

inline void append(std::vector<uml::platform::DecodedVideoFrame>& all, std::vector<uml::platform::DecodedVideoFrame> more)
{
    for (auto& frame : more) all.push_back(std::move(frame));
}


} // namespace uml::testing::video_decoder
