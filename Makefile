+/*******************************************************************************
2	+File: 		port_forwarder.c
3	+
4	+Usage:				
5	+	
6	+Authors:	Jeremy Tsang, Kevin Eng		
7	+	
8	+Date:		March 22, 2014
9	+
10	+Purpose:	COMP 8005 Assignment 3 - Basic Application Level Port Forwarder
11	+
12	+*******************************************************************************/
13	+#include <arpa/inet.h>
14	+#include <assert.h>
15	+#include <errno.h>
16	+#include <fcntl.h>
17	+#include <netdb.h>
18	+#include <netinet/in.h>
19	+#include <pthread.h>
20	+#include <signal.h>
21	+#include <stdio.h>
22	+#include <stdlib.h>
23	+#include <string.h>
24	+#include <sys/epoll.h>
25	+#include <sys/socket.h>
26	+#include <sys/time.h>
27	+#include <sys/types.h>
28	+#include <unistd.h>
29	+
30	+
31	+
32	+/*******************************************************************************
33	+Definitions
34	+*******************************************************************************/
35	+#define TRUE 				1
36	+#define FALSE 				0
37	+#define EPOLL_QUEUE_LEN			256
38	+#define BUFLEN				800
39	+
40	+
41	+/* cinfo for storing client socket info*/
42	+typedef struct{
43	+	int fd;		// Socket descriptor
44	+	int fd_pair;	// Corresponding socket to forward to
45	+}cinfo;
46	+
47	+
48	+/* sinfo for storing server socket info */
49	+typedef struct{
50	+	int fd;		// Socket descriptor
51	+	char * server;	// Server to forward to
52	+	int server_port;// Server port
53	+}sinfo;
54	+
55	+
56	+
57	+/*******************************************************************************
58	+Globals and Prototypes
59	+*******************************************************************************/
60	+/* Globals */
61	+sinfo ** servers = NULL;	// Array of server sockets listening
62	+int servers_size = 0;
63	+
64	+
65	+/* Function prototypes */
66	+static void SystemFatal (const char* message);
67	+static int ClearSocket (int fd);
68	+void close_server (int);
69	+sinfo * is_server(int fd);
70	+
71	+
72	+
73	+/*******************************************************************************
74	+Functions
75	+*******************************************************************************/
76	+/* Main */
77	+int main (int argc, char* argv[]) {
78	+
79	+	int i, arg; 
80	+	int num_fds, epoll_fd;
81	+	static struct epoll_event events[EPOLL_QUEUE_LEN], event;
82	+	struct sigaction act;
83	+	
84	+	// set up the signal handler to close the server socket when CTRL-c is received
85	+   	act.sa_handler = close_server;
86	+    	act.sa_flags = 0;
87	+    	if ((sigemptyset (&act.sa_mask) == -1 || sigaction (SIGINT, &act, NULL) == -1)){
88	+		perror ("Failed to set SIGINT handler");
89	+		exit (EXIT_FAILURE);
90	+	}
91	+	
92	+	// Create the epoll file descriptor
93	+	epoll_fd = epoll_create(EPOLL_QUEUE_LEN);
94	+	if (epoll_fd == -1) 
95	+		SystemFatal("epoll_create");
96	+	
97	+	// Read config file and create all listening sockets and add to epoll
98	+	FILE * fp;
99	+	ssize_t read;
100	+	size_t len = 0;
101	+	char * line = NULL;
102	+	
103	+	fp = fopen("port_forwarder.conf","r");
104	+	while((read = getline(&line, &len, fp)) != -1){
105	+		
106	+		// Tokenize each line into array
107	+		char * token;
108	+		char * config[3];
109	+		int config_index = 0;
110	+		
111	+		token = strtok(line,",");
112	+		while(token != NULL){
113	+			config[config_index++] = token;
114	+			token = strtok(NULL,",");
115	+		}
116	+		//printf("Tokenized into %d\n",config_index);
117	+		
118	+		// Info from each line
119	+		int port = atoi(config[0]);
120	+		char * server = config[1];
121	+		int server_port = atoi(config[2]);
122	+		
123	+		// Create the listening socket
124	+		int fd_server;
125	+
126	+		fd_server = socket (AF_INET, SOCK_STREAM, 0);
127	+		if (fd_server == -1) 
128	+			SystemFatal("socket");
129	+	
130	+		// set SO_REUSEADDR so port can be reused immediately after exit, i.e., after CTRL-c
131	+		arg = 1;
132	+		if (setsockopt (fd_server, SOL_SOCKET, SO_REUSEADDR, &arg, sizeof(arg)) == -1) 
133	+			SystemFatal("setsockopt");
134	+	
135	+		// Make the server listening socket non-blocking
136	+		if (fcntl (fd_server, F_SETFL, O_NONBLOCK | fcntl (fd_server, F_GETFL, 0)) == -1) 
137	+			SystemFatal("fcntl");
138	+	
139	+		// Bind to the specified listening port
140	+		struct sockaddr_in addr;
141	+		memset (&addr, 0, sizeof (struct sockaddr_in));
142	+		addr.sin_family = AF_INET;
143	+		addr.sin_addr.s_addr = htonl(INADDR_ANY);
144	+		addr.sin_port = htons(port);
145	+		
146	+		printf("Listening on port %d...\n",port);
147	+		
148	+		if (bind (fd_server, (struct sockaddr*) &addr, sizeof(addr)) == -1) 
149	+			SystemFatal("bind");
150	+	
151	+		// Listen for fd_news; SOMAXCONN is 128 by default
152	+		if (listen (fd_server, SOMAXCONN) == -1) 
153	+			SystemFatal("listen");
154	+	
155	+		// Add to server list
156	+		sinfo * server_sinfo = malloc(sizeof(sinfo));
157	+		server_sinfo->fd = fd_server;
158	+		server_sinfo->server = server;
159	+		server_sinfo->server_port = server_port;
160	+		
161	+		servers = realloc(servers,sizeof(sinfo *) * servers_size);
162	+		servers[servers_size++] = server_sinfo;
163	+	
164	+		// Add the server socket to the epoll event loop with it's data
165	+		event.events = EPOLLIN | EPOLLERR | EPOLLHUP | EPOLLET;
166	+		
167	+		cinfo * server_cinfo = malloc(sizeof(cinfo));
168	+		server_cinfo->fd = fd_server;
169	+		event.data.ptr = (void *)server_cinfo;
170	+	
171	+		if (epoll_ctl (epoll_fd, EPOLL_CTL_ADD, fd_server, &event) == -1)
172	+			SystemFatal("epoll_ctl");
173	+	}
174	+	
175	+	if(line)
176	+		free(line);
177	+	
178	+	fclose(fp);
179	+    
180	+	// Execute the epoll event loop
181	+	while (TRUE){
182	+	
183	+		//fprintf(stdout,"epoll wait\n");
184	+		
185	+		num_fds = epoll_wait (epoll_fd, events, EPOLL_QUEUE_LEN, -1);
186	+		if (num_fds < 0)
187	+			SystemFatal ("epoll_wait");
188	+
189	+		for (i = 0; i < num_fds; i++){
190	+			
191	+	    		// EPOLLHUP
192	+	    		if (events[i].events & EPOLLHUP){
193	+	    		
194	+	    			// Get socket cinfo
195	+	    			cinfo * c_ptr = (cinfo *)events[i].data.ptr;
196	+    		
197	+				fprintf(stdout,"EPOLLHUP - closing fd: %d\n", c_ptr->fd);
198	+				
199	+				close(c_ptr->fd);
200	+				//free(c_ptr);
201	+				
202	+				continue;
203	+			}
204	+			
205	+			// EPOLLERR
206	+			if (events[i].events & EPOLLERR){
207	+			
208	+				// Get socket cinfo
209	+    				cinfo * c_ptr = (cinfo *)events[i].data.ptr;
210	+			
211	+				fprintf(stdout,"EPOLLERR - closing fd: %d\n", c_ptr->fd);
212	+				
213	+				close(c_ptr->fd);
214	+				
215	+				continue;
216	+			}
217	+			
218	+	    		assert (events[i].events & EPOLLIN);
219	+	    						
220	+	    		// EPOLLIN
221	+	    		if (events[i].events & EPOLLIN){
222	+    				
223	+				// Get socket cinfo
224	+				cinfo * c_ptr = (cinfo *)events[i].data.ptr;
225	+	    			
226	+				// Server is receiving one or more incoming connection requests
227	+				sinfo * s_ptr = NULL;
228	+				if ((s_ptr = is_server(c_ptr->fd)) != NULL){
229	+				
230	+					printf("EPOLLIN - incoming connection fd:%d\n",s_ptr->fd);
231	+					
232	+					while(1){
233	+								
234	+						struct sockaddr_in in_addr;
235	+						socklen_t in_len;
236	+						int fd_new = 0;
237	+						
238	+						//memset (&in_addr, 1, sizeof (struct sockaddr_in));
239	+						fd_new = accept(s_ptr->fd, (struct sockaddr *)&in_addr, &in_len);
240	+						if (fd_new == -1){
241	+							// If error in accept call
242	+							if (errno != EAGAIN && errno != EWOULDBLOCK)
243	+								SystemFatal("accept");//perror("accept");
244	+								
245	+							perror("wat");
246	+							// All connections have been processed
247	+							break;
248	+						}
249	+						
250	+						printf("EPOLLIN - connected fd: %d\n", fd_new);
251	+						
252	+						// Make the fd_new non-blocking
253	+						if (fcntl (fd_new, F_SETFL, O_NONBLOCK | fcntl(fd_new, F_GETFL, 0)) == -1) 
254	+							SystemFatal("fcntl");
255	+				
256	+						event.events = EPOLLIN | EPOLLERR | EPOLLHUP | EPOLLET;
257	+						
258	+						cinfo * client_info = malloc(sizeof(cinfo));
259	+						client_info->fd = fd_new;
260	+						event.data.ptr = (void *)client_info;
261	+						
262	+						if (epoll_ctl (epoll_fd, EPOLL_CTL_ADD, fd_new, &event) == -1) 
263	+							SystemFatal ("epoll_ctl");
264	+
265	+						continue;
266	+					}
267	+				}
268	+				// Else one of the sockets has read data
269	+				else{
270	+					fprintf(stdout,"EPOLLIN - read fd: %d\n", c_ptr->fd);
271	+					
272	+					if (!ClearSocket(c_ptr->fd)){
273	+						// epoll will remove the fd from its set
274	+						// automatically when the fd is closed
275	+						close(c_ptr->fd);
276	+					}
277	+				}
278	+			}
279	+		}
280	+	}
281	+	
282	+	exit (EXIT_SUCCESS);
283	+}
284	+
285	+
286	+/* Read Buffer */
287	+static int ClearSocket (int fd) {
288	+	int	n, bytes_to_read, m = 0;
289	+	char	*bp, buf[BUFLEN];
290	+		
291	+	bp = buf;
292	+	bytes_to_read = BUFLEN;
293	+	
294	+	// Edge-triggered event will only notify once, so we must
295	+	// read everything in the buffer
296	+	while(1){
297	+		n = recv (fd, bp, bytes_to_read, 0);
298	+	
299	+		// Read message
300	+		if(n > 0){
301	+			m++;
302	+			
303	+			printf ("Read (%d) bytes on fd %d:\n%s\n", n, fd, buf);
304	+			
305	+			/*int l = send(fd, buf, BUFLEN, 0);
306	+			if(l == -1){
307	+				
308	+			}*/
309	+		}
310	+		// No more messages or read error
311	+		else if(n == -1){
312	+			if(errno != EAGAIN && errno != EWOULDBLOCK)
313	+				perror("recv");
314	+			
315	+			break;
316	+		}
317	+		// Wrong message size or zero-length message
318	+		// Stream socket peer has performed an orderly shutdown
319	+		else{
320	+			printf ("Shutdown on fd %d\n", fd);
321	+			break;
322	+		}
323	+	}
324	+	
325	+	//printf ("sending m:%d\n", m);
326	+	
327	+	if(m == 0)
328	+		return FALSE;
329	+	else
330	+		return TRUE;
331	+	/*
332	+	while ((n = recv (fd, bp, bytes_to_read, 0)) > 0)
333	+	{
334	+		bp += n;
335	+		bytes_to_read -= n;
336	+		m++;
337	+	}
338	+	
339	+	if(m == 0)
340	+		return FALSE;
341	+	
342	+	//printf ("sending:%s\tloops:%d\n", buf, m);
343	+	printf ("sending:%s\n", buf);
344	+
345	+	send (fd, buf, BUFLEN, 0);
346	+	//close (fd);
347	+	return TRUE;*/
348	+}
349	+
350	+
351	+/* Prints the error stored in errno and aborts the program. */
352	+static void SystemFatal(const char* message) {
353	+    perror (message);
354	+    exit (EXIT_FAILURE);
355	+}
356	+
357	+
358	+/* Server closing function, signalled by CTRL-C. */
359	+void close_server (int signo){
360	+    	int c = 0;
361	+    	for(;c < servers_size;c++){
362	+		close(servers[c]->fd);
363	+    	}
364	+	exit (EXIT_SUCCESS);
365	+}
366	+
+
368	+/* Check if fd is a server socket. */
369	+sinfo * is_server(int fd){
370	+	int c = 0;
371	+	for(;c < servers_size;c++){
372	+		if(servers[c]->fd == fd)
373	+			return servers[c];
374	+	}
375	+	return NULL;
	376	+}
377     +
