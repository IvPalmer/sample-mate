// Head-to-head reference arm: runs libKeyFinder (the real GPL engine) on WAVs.
// Build: g++ -std=c++11 kf.cpp -o kf -I$(brew --prefix)/include -L$(brew --prefix)/lib -lkeyfinder -lsndfile
// Use:   ./kf file.wav [more.wav ...]   -> prints  KEY<TAB>file
#include <keyfinder/keyfinder.h>
#include <keyfinder/audiodata.h>
#include <sndfile.h>
#include <cstdio>
#include <vector>
#include <string>

// enum key_t order -> sharp-spelled label matching the Swift detector / grader
static const char* LABELS[25] = {
    "A","Am","A#","A#m","B","Bm","C","Cm","C#","C#m","D","Dm",
    "D#","D#m","E","Em","F","Fm","F#","F#m","G","Gm","G#","G#m","-"
};

int main(int argc, char** argv) {
    KeyFinder::KeyFinder kf;             // reuse across files
    for (int ai = 1; ai < argc; ai++) {
        const char* path = argv[ai];
        SF_INFO info; info.format = 0;
        SNDFILE* sf = sf_open(path, SFM_READ, &info);
        if (!sf) { printf("ERR\t%s\n", path); continue; }
        sf_count_t frames = info.frames;
        int ch = info.channels;
        std::vector<double> buf((size_t)frames * ch);
        sf_readf_double(sf, buf.data(), frames);
        sf_close(sf);
        try {
            KeyFinder::AudioData a;
            a.setFrameRate((unsigned)info.samplerate);
            a.setChannels((unsigned)ch);
            a.addToSampleCount((unsigned)(buf.size()));
            for (size_t i = 0; i < buf.size(); i++) a.setSample((unsigned)i, buf[i]);
            KeyFinder::key_t key = kf.keyOfAudio(a);
            printf("%s\t%s\n", LABELS[(int)key], path);
        } catch (const std::exception& e) {
            printf("-\t%s\n", path);     // too short / silent -> no tag
        }
        fflush(stdout);
    }
    return 0;
}
