#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void check(int result) { if(result < 0) { fprintf(stderr,"mpv API failure: %d\n", result); exit(2); } }
int main(int argc, char **argv) {
  if(argc != 3) return 2;
  mpv_handle *m = mpv_create();
  check(mpv_set_option_string(m,"vo","null")); check(mpv_set_option_string(m,"ao","null"));
  check(mpv_set_option_string(m,"idle","yes")); check(mpv_set_option_string(m,"terminal","no"));
  check(mpv_initialize(m)); check(mpv_hook_add(m,1,"on_load",20));
  const char *first[]={"loadfile","iina-jellyfin://direct","replace",NULL}; check(mpv_command(m,first));
  const char *local[]={"loadfile",argv[2],"append",NULL}; check(mpv_command(m,local));
  const char *hls[]={"loadfile","iina-jellyfin://hls","append",NULL}; check(mpv_command(m,hls));
  int loaded=0,ended=0; time_t deadline=time(NULL)+25;
  while(time(NULL)<deadline && ended<3) {
    mpv_event *e=mpv_wait_event(m,0.2);
    if(e->event_id == MPV_EVENT_HOOK) {
      char *path=mpv_get_property_string(m,"path");
      if(path && strncmp(path,"iina-jellyfin:",14)==0) {
        char target[512]; snprintf(target,sizeof(target),"%s/%s",argv[1],strstr(path,"direct")?"clip.mp4":"hls.m3u8");
        check(mpv_set_property_string(m,"file-local-options/http-header-fields","X-Emby-Token: test-token"));
        check(mpv_set_property_string(m,"stream-open-filename",target));
      }
      mpv_free(path); check(mpv_hook_continue(m,((mpv_event_hook *)e->data)->id));
    } else if(e->event_id == MPV_EVENT_FILE_LOADED) {
      char *path=mpv_get_property_string(m,"path");
      const char *expected=loaded==0?"iina-jellyfin://direct":loaded==1?argv[2]:"iina-jellyfin://hls";
      if(!path || strcmp(path,expected)) { fprintf(stderr,"Stable playlist identity changed\n"); return 3; }
      mpv_free(path); loaded++;
      if(loaded==1) {
        int64_t id; check(mpv_get_property(m,"playlist/0/id",MPV_FORMAT_INT64,&id));
        const char *move[]={"playlist-move","2","1",NULL}; check(mpv_command(m,move)); check(mpv_command(m,move));
        const char *extra[]={"loadfile",argv[2],"append",NULL}; check(mpv_command(m,extra));
        const char *remove[]={"playlist-remove","3",NULL}; check(mpv_command(m,remove));
        int64_t current; check(mpv_get_property(m,"playlist/0/id",MPV_FORMAT_INT64,&current));
        if(id != current) return 4;
      }
    } else if(e->event_id == MPV_EVENT_END_FILE) {
      mpv_event_end_file *end=e->data;
      if(end->reason==MPV_END_FILE_REASON_ERROR) { fprintf(stderr,"Stream failed: %d\n",end->error); return 5; }
      ended++;
    }
  }
  mpv_terminate_destroy(m);
  if(loaded!=3 || ended!=3) { fprintf(stderr,"Playback did not advance: loaded=%d ended=%d\n",loaded,ended); return 6; }
  puts("PASS: real libmpv stable identities, reorder/append/remove without restart, and direct → local → HLS automatic advance");
}
