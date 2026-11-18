// SPDX-License-Identifier: GPL-2.0-or-later
#include "nv12_transform.hpp"
#include "require.hpp"

#include <cstdint>
#include <vector>

using namespace uml::platform;
using uml::testing::require;

namespace {

struct Picture {
    std::uint32_t width, height;
    std::vector<std::uint8_t> luma, chroma;
    Picture(std::uint32_t w, std::uint32_t h) : width(w), height(h), luma(std::size_t(w) * h), chroma(std::size_t(w) * h / 2) {}
    Nv12Source source() const { return {luma.data(), width, chroma.data(), width, width, height}; }
    Nv12Target target() { return {luma.data(), width, chroma.data(), width, width, height}; }
};

// Each luma sample is its own position, so any misplacement shows.
Picture ramp(std::uint32_t width, std::uint32_t height)
{
    Picture picture(width, height);
    for (std::uint32_t y = 0; y < height; ++y)
        for (std::uint32_t x = 0; x < width; ++x) picture.luma[std::size_t(y) * width + x] = std::uint8_t(y * 16 + x);
    for (std::uint32_t y = 0; y < height / 2; ++y)
        for (std::uint32_t x = 0; x < width / 2; ++x) {
            picture.chroma[std::size_t(y) * width + x * 2] = std::uint8_t(100 + y * 8 + x);
            picture.chroma[std::size_t(y) * width + x * 2 + 1] = std::uint8_t(200 + y * 8 + x);
        }
    return picture;
}

void crops()
{
    // A 16:9 target of a 4:3 picture takes the full width and the middle band.
    auto crop = centredCrop(640, 480, 1920, 1080);
    require(crop.width == 640 && crop.height == 360 && crop.x == 0 && crop.y == 60);
    // The reverse takes the full height and the middle columns.
    crop = centredCrop(1920, 1080, 640, 480);
    require(crop.width == 1440 && crop.height == 1080 && crop.x == 240 && crop.y == 0);
    // Equal aspect is the whole picture.
    crop = centredCrop(1280, 720, 640, 360);
    require(crop == Nv12Rect({0, 0, 1280, 720}));
    // A quarter turn swaps the target's aspect: a portrait target of a landscape picture.
    crop = centredCrop(1920, 1080, 1080, 1920, true);
    require(crop.width == 1920 && crop.height == 1080);
    crop = centredCrop(1920, 1080, 1080, 1920, false);
    require(crop.width == 606 && crop.height == 1080);
    // Everything is even.
    crop = centredCrop(1001, 777, 5, 3);
    require(crop.x % 2 == 0 && crop.y % 2 == 0 && crop.width % 2 == 0 && crop.height % 2 == 0);
    require(centredCrop(0, 10, 4, 4) == Nv12Rect {});
}

void identityAndRotation()
{
    const auto source = ramp(8, 4);
    Picture same(8, 4);
    require(transformNv12(source.source(), {0, 0, 8, 4}, 0, same.target()));
    require(same.luma == source.luma && same.chroma == source.chroma);

    // Clockwise 90: the source's left column becomes the top row, read bottom to top.
    Picture turned(4, 8);
    require(transformNv12(source.source(), {0, 0, 8, 4}, 90, turned.target()));
    for (std::uint32_t v = 0; v < 8; ++v)
        for (std::uint32_t u = 0; u < 4; ++u)
            require(turned.luma[std::size_t(v) * 4 + u] == source.luma[std::size_t(4 - 1 - u) * 8 + v]);
    // Chroma pairs stay Cb then Cr.
    for (std::uint32_t v = 0; v < 4; ++v)
        for (std::uint32_t u = 0; u < 2; ++u) {
            require(turned.chroma[std::size_t(v) * 4 + u * 2] == source.chroma[std::size_t(2 - 1 - u) * 8 + v * 2]);
            require(turned.chroma[std::size_t(v) * 4 + u * 2 + 1] == source.chroma[std::size_t(2 - 1 - u) * 8 + v * 2 + 1]);
        }
    // 180 reverses both axes; 270 undoes 90.
    Picture flipped(8, 4);
    require(transformNv12(source.source(), {0, 0, 8, 4}, 180, flipped.target()));
    for (std::uint32_t y = 0; y < 4; ++y)
        for (std::uint32_t x = 0; x < 8; ++x)
            require(flipped.luma[std::size_t(y) * 8 + x] == source.luma[std::size_t(3 - y) * 8 + (7 - x)]);
    Picture back(8, 4);
    require(transformNv12(turned.source(), {0, 0, 4, 8}, 270, back.target()));
    require(back.luma == source.luma && back.chroma == source.chroma);
}

void cropAndScale()
{
    const auto source = ramp(8, 8);
    // A crop at an offset, copied unscaled.
    Picture window(4, 4);
    require(transformNv12(source.source(), {2, 2, 4, 4}, 0, window.target()));
    for (std::uint32_t y = 0; y < 4; ++y)
        for (std::uint32_t x = 0; x < 4; ++x) require(window.luma[std::size_t(y) * 4 + x] == source.luma[std::size_t(y + 2) * 8 + x + 2]);
    require(window.chroma[0] == source.chroma[1 * 8 + 1 * 2] && window.chroma[1] == source.chroma[1 * 8 + 1 * 2 + 1]);

    // A downscale by two averages 2 x 2 blocks.
    Picture half(4, 4);
    require(transformNv12(source.source(), {0, 0, 8, 8}, 0, half.target()));
    for (std::uint32_t y = 0; y < 4; ++y)
        for (std::uint32_t x = 0; x < 4; ++x) {
            const unsigned sum = source.luma[std::size_t(2 * y) * 8 + 2 * x] + source.luma[std::size_t(2 * y) * 8 + 2 * x + 1] +
                source.luma[std::size_t(2 * y + 1) * 8 + 2 * x] + source.luma[std::size_t(2 * y + 1) * 8 + 2 * x + 1];
            require(half.luma[std::size_t(y) * 4 + x] == (sum + 2) / 4);
        }

    // An upscale of a flat picture stays flat, and a ramp stays between its ends.
    Picture flat(4, 4);
    for (auto& v : flat.luma) v = 77;
    for (auto& v : flat.chroma) v = 99;
    Picture big(16, 12);
    require(transformNv12(flat.source(), {0, 0, 4, 4}, 0, big.target()));
    for (const auto v : big.luma) require(v == 77);
    for (const auto v : big.chroma) require(v == 99);
    Picture wide(8, 4);
    for (std::uint32_t y = 0; y < 4; ++y)
        for (std::uint32_t x = 0; x < 8; ++x) wide.luma[std::size_t(y) * 8 + x] = std::uint8_t(x * 30);
    Picture stretched(16, 4);
    require(transformNv12(wide.source(), {0, 0, 8, 4}, 0, stretched.target()));
    for (std::uint32_t x = 1; x < 16; ++x) require(stretched.luma[x] >= stretched.luma[x - 1]);
    require(stretched.luma[0] == 0 && stretched.luma[15] == 210);
}

void refusals()
{
    const auto source = ramp(8, 8);
    Picture target(4, 4);
    require(!transformNv12(source.source(), {0, 0, 8, 8}, 45, target.target()));
    require(!transformNv12(source.source(), {2, 2, 8, 8}, 0, target.target()));  // outside
    require(!transformNv12(source.source(), {1, 0, 4, 4}, 0, target.target()));  // odd
    Picture odd(3, 4);
    require(!transformNv12(source.source(), {0, 0, 8, 8}, 0, odd.target()));
    auto narrow = target.target();
    narrow.lumaStride = 2;
    require(!transformNv12(source.source(), {0, 0, 8, 8}, 0, narrow));
    auto empty = source.source();
    empty.luma = nullptr;
    require(!transformNv12(empty, {0, 0, 8, 8}, 0, target.target()));
}

void black()
{
    Picture picture(6, 4);
    for (auto& v : picture.luma) v = 200;
    for (auto& v : picture.chroma) v = 9;
    fillNv12Black(picture.target());
    for (const auto v : picture.luma) require(v == 0);
    for (const auto v : picture.chroma) require(v == 128);
}

} // namespace

int main()
{
    crops();
    identityAndRotation();
    cropAndScale();
    refusals();
    black();
    return 0;
}
