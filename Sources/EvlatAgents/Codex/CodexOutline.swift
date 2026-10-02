import Foundation

// The mark below is codenotch's outline of OpenAI's
// (https://github.com/vinzdg/codenotch, `Sources/Providers/GlyphOutline.swift`),
// used under its licence:
//
// MIT License
//
// Copyright (c) 2026 Vinz
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

extension Codex {
    /// OpenAI's knot, traced: a unit box, filled even-odd so its counters
    /// stay open (`AgentDisplay.outline`).
    static let outline: [[CGPoint]] = [
        [CGPoint(x: 0.4234, y: -0.0272), CGPoint(x: 0.3541, y: -0.0187), CGPoint(x: 0.3013, y: 0.0040), 
         CGPoint(x: 0.2422, y: 0.0495), CGPoint(x: 0.2012, y: 0.1069), CGPoint(x: 0.1823, y: 0.1455), 
         CGPoint(x: 0.1435, y: 0.1661), CGPoint(x: 0.1104, y: 0.1756), CGPoint(x: 0.0468, y: 0.2232), 
         CGPoint(x: 0.0013, y: 0.2863), CGPoint(x: -0.0216, y: 0.3430), CGPoint(x: -0.0275, y: 0.4147), 
         CGPoint(x: -0.0212, y: 0.4800), CGPoint(x: 0.0021, y: 0.5354), CGPoint(x: 0.0380, y: 0.5897), 
         CGPoint(x: 0.0271, y: 0.6302), CGPoint(x: 0.0242, y: 0.6634), CGPoint(x: 0.0281, y: 0.7123), 
         CGPoint(x: 0.0453, y: 0.7686), CGPoint(x: 0.0889, y: 0.8376), CGPoint(x: 0.1131, y: 0.8638), 
         CGPoint(x: 0.1823, y: 0.9074), CGPoint(x: 0.2413, y: 0.9266), CGPoint(x: 0.3060, y: 0.9300), 
         CGPoint(x: 0.3346, y: 0.9264), CGPoint(x: 0.3516, y: 0.9307), CGPoint(x: 0.4021, y: 0.9710), 
         CGPoint(x: 0.4298, y: 0.9808), CGPoint(x: 0.4562, y: 0.9973), CGPoint(x: 0.5234, y: 1.0093), 
         CGPoint(x: 0.5785, y: 1.0094), CGPoint(x: 0.6468, y: 0.9924), CGPoint(x: 0.7148, y: 0.9513), 
         CGPoint(x: 0.7772, y: 0.8832), CGPoint(x: 0.8042, y: 0.8303), CGPoint(x: 0.8365, y: 0.8205), 
         CGPoint(x: 0.8821, y: 0.7975), CGPoint(x: 0.9458, y: 0.7449), CGPoint(x: 0.9740, y: 0.7075), 
         CGPoint(x: 0.9957, y: 0.6627), CGPoint(x: 1.0095, y: 0.5968), CGPoint(x: 1.0090, y: 0.5479), 
         CGPoint(x: 0.9945, y: 0.4764), CGPoint(x: 0.9451, y: 0.3970), CGPoint(x: 0.9551, y: 0.3353), 
         CGPoint(x: 0.9516, y: 0.2607), CGPoint(x: 0.9295, y: 0.1997), CGPoint(x: 0.8836, y: 0.1329), 
         CGPoint(x: 0.8279, y: 0.0900), CGPoint(x: 0.7854, y: 0.0679), CGPoint(x: 0.7109, y: 0.0532), 
         CGPoint(x: 0.6410, y: 0.0590), CGPoint(x: 0.6009, y: 0.0243), CGPoint(x: 0.5658, y: 0.0021), 
         CGPoint(x: 0.5325, y: -0.0075), CGPoint(x: 0.5138, y: -0.0192), CGPoint(x: 0.4237, y: -0.0273)],
        [CGPoint(x: 0.5915, y: 0.6193), CGPoint(x: 0.6003, y: 0.6198), CGPoint(x: 0.6051, y: 0.6294), 
         CGPoint(x: 0.6065, y: 0.6987), CGPoint(x: 0.6030, y: 0.7094), CGPoint(x: 0.5791, y: 0.7311), 
         CGPoint(x: 0.5493, y: 0.7434), CGPoint(x: 0.4991, y: 0.7768), CGPoint(x: 0.4755, y: 0.7856), 
         CGPoint(x: 0.3803, y: 0.8423), CGPoint(x: 0.3101, y: 0.8617), CGPoint(x: 0.2639, y: 0.8607), 
         CGPoint(x: 0.2101, y: 0.8447), CGPoint(x: 0.1602, y: 0.8126), CGPoint(x: 0.1332, y: 0.7824), 
         CGPoint(x: 0.1099, y: 0.7456), CGPoint(x: 0.0966, y: 0.6858), CGPoint(x: 0.0971, y: 0.6532), 
         CGPoint(x: 0.1028, y: 0.6439), CGPoint(x: 0.1253, y: 0.6483), CGPoint(x: 0.1529, y: 0.6679), 
         CGPoint(x: 0.1798, y: 0.6772), CGPoint(x: 0.2300, y: 0.7111), CGPoint(x: 0.2579, y: 0.7211), 
         CGPoint(x: 0.3071, y: 0.7554), CGPoint(x: 0.3359, y: 0.7601), CGPoint(x: 0.3530, y: 0.7554), 
         CGPoint(x: 0.5913, y: 0.6194)],
        [CGPoint(x: 0.1549, y: 0.2337), CGPoint(x: 0.1661, y: 0.2362), CGPoint(x: 0.1713, y: 0.2520), 
         CGPoint(x: 0.1740, y: 0.4890), CGPoint(x: 0.2443, y: 0.5383), CGPoint(x: 0.3815, y: 0.6098), 
         CGPoint(x: 0.3978, y: 0.6261), CGPoint(x: 0.4244, y: 0.6356), CGPoint(x: 0.4284, y: 0.6478), 
         CGPoint(x: 0.4203, y: 0.6616), CGPoint(x: 0.3691, y: 0.6910), CGPoint(x: 0.3509, y: 0.6950), 
         CGPoint(x: 0.3314, y: 0.6910), CGPoint(x: 0.3149, y: 0.6770), CGPoint(x: 0.2011, y: 0.6118), 
         CGPoint(x: 0.1787, y: 0.6039), CGPoint(x: 0.1148, y: 0.5618), CGPoint(x: 0.0696, y: 0.5126), 
         CGPoint(x: 0.0463, y: 0.4673), CGPoint(x: 0.0413, y: 0.4222), CGPoint(x: 0.0428, y: 0.3713), 
         CGPoint(x: 0.0661, y: 0.3121), CGPoint(x: 0.1072, y: 0.2634), CGPoint(x: 0.1340, y: 0.2422), 
         CGPoint(x: 0.1549, y: 0.2337)],
        [CGPoint(x: 0.6595, y: 0.4590), CGPoint(x: 0.6735, y: 0.4607), CGPoint(x: 0.7335, y: 0.5002), 
         CGPoint(x: 0.7409, y: 0.5112), CGPoint(x: 0.7407, y: 0.7673), CGPoint(x: 0.7335, y: 0.8119), 
         CGPoint(x: 0.6907, y: 0.8831), CGPoint(x: 0.6628, y: 0.9073), CGPoint(x: 0.6193, y: 0.9293), 
         CGPoint(x: 0.5683, y: 0.9410), CGPoint(x: 0.4861, y: 0.9339), CGPoint(x: 0.4346, y: 0.9106), 
         CGPoint(x: 0.4283, y: 0.8998), CGPoint(x: 0.4330, y: 0.8914), CGPoint(x: 0.4606, y: 0.8724), 
         CGPoint(x: 0.5577, y: 0.8212), CGPoint(x: 0.5741, y: 0.8071), CGPoint(x: 0.5975, y: 0.7986), 
         CGPoint(x: 0.6123, y: 0.7854), CGPoint(x: 0.6347, y: 0.7751), CGPoint(x: 0.6475, y: 0.7604), 
         CGPoint(x: 0.6525, y: 0.7361), CGPoint(x: 0.6513, y: 0.4738), CGPoint(x: 0.6592, y: 0.4591)],
        [CGPoint(x: 0.4201, y: 0.0407), CGPoint(x: 0.4901, y: 0.0454), CGPoint(x: 0.5415, y: 0.0677), 
         CGPoint(x: 0.5485, y: 0.0825), CGPoint(x: 0.5360, y: 0.1008), CGPoint(x: 0.5091, y: 0.1112), 
         CGPoint(x: 0.4589, y: 0.1456), CGPoint(x: 0.3563, y: 0.1987), CGPoint(x: 0.3290, y: 0.2258), 
         CGPoint(x: 0.3275, y: 0.5024), CGPoint(x: 0.3233, y: 0.5161), CGPoint(x: 0.3135, y: 0.5208), 
         CGPoint(x: 0.3039, y: 0.5183), CGPoint(x: 0.2881, y: 0.5027), CGPoint(x: 0.2618, y: 0.4935), 
         CGPoint(x: 0.2379, y: 0.4671), CGPoint(x: 0.2377, y: 0.2259), CGPoint(x: 0.2419, y: 0.1878), 
         CGPoint(x: 0.2623, y: 0.1376), CGPoint(x: 0.3041, y: 0.0883), CGPoint(x: 0.3313, y: 0.0668), 
         CGPoint(x: 0.3713, y: 0.0482), CGPoint(x: 0.4197, y: 0.0407)],
        [CGPoint(x: 0.6793, y: 0.1223), CGPoint(x: 0.7157, y: 0.1231), CGPoint(x: 0.7641, y: 0.1328), 
         CGPoint(x: 0.8047, y: 0.1561), CGPoint(x: 0.8276, y: 0.1768), CGPoint(x: 0.8625, y: 0.2233), 
         CGPoint(x: 0.8807, y: 0.2686), CGPoint(x: 0.8876, y: 0.3190), CGPoint(x: 0.8831, y: 0.3376), 
         CGPoint(x: 0.8696, y: 0.3399), CGPoint(x: 0.8290, y: 0.3206), CGPoint(x: 0.7808, y: 0.2871), 
         CGPoint(x: 0.7555, y: 0.2771), CGPoint(x: 0.7028, y: 0.2432), CGPoint(x: 0.6491, y: 0.2198), 
         CGPoint(x: 0.6010, y: 0.2420), CGPoint(x: 0.3950, y: 0.3609), CGPoint(x: 0.3770, y: 0.3587), 
         CGPoint(x: 0.3753, y: 0.2836), CGPoint(x: 0.3855, y: 0.2637), CGPoint(x: 0.6109, y: 0.1354), 
         CGPoint(x: 0.6793, y: 0.1223)],
        [CGPoint(x: 0.6168, y: 0.2853), CGPoint(x: 0.6369, y: 0.2862), CGPoint(x: 0.8593, y: 0.4128), 
         CGPoint(x: 0.9080, y: 0.4616), CGPoint(x: 0.9290, y: 0.4972), CGPoint(x: 0.9405, y: 0.5690), 
         CGPoint(x: 0.9306, y: 0.6410), CGPoint(x: 0.9050, y: 0.6876), CGPoint(x: 0.8550, y: 0.7354), 
         CGPoint(x: 0.8203, y: 0.7467), CGPoint(x: 0.8106, y: 0.7381), CGPoint(x: 0.8105, y: 0.5166), 
         CGPoint(x: 0.8003, y: 0.4834), CGPoint(x: 0.7040, y: 0.4293), CGPoint(x: 0.6883, y: 0.4155), 
         CGPoint(x: 0.6661, y: 0.4077), CGPoint(x: 0.5469, y: 0.3401), CGPoint(x: 0.5506, y: 0.3260), 
         CGPoint(x: 0.6001, y: 0.2999), CGPoint(x: 0.6168, y: 0.2853)],
        [CGPoint(x: 0.4779, y: 0.3668), CGPoint(x: 0.5139, y: 0.3713), CGPoint(x: 0.5650, y: 0.4061), 
         CGPoint(x: 0.5917, y: 0.4164), CGPoint(x: 0.6023, y: 0.4290), CGPoint(x: 0.6061, y: 0.4482), 
         CGPoint(x: 0.6032, y: 0.5543), CGPoint(x: 0.5631, y: 0.5821), CGPoint(x: 0.4922, y: 0.6155), 
         CGPoint(x: 0.4806, y: 0.6145), CGPoint(x: 0.4134, y: 0.5801), CGPoint(x: 0.3827, y: 0.5553), 
         CGPoint(x: 0.3749, y: 0.5304), CGPoint(x: 0.3747, y: 0.4480), CGPoint(x: 0.3821, y: 0.4243), 
         CGPoint(x: 0.4778, y: 0.3668)],
    ]
}
