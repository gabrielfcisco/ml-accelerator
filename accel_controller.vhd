library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- FSM do acelerador. Sequencia LOAD / COMPUTE / STORE / DONE.
-- Para cada grupo de 4 neuronios:
--   COMPUTE: itera k = 0..M-1 acumulando x[k]*w_lane[k] em cada MAC
--   STORE:   serializa em 4 ciclos a escrita dos 4 acumuladores no output buffer
-- Em seguida limpa as MACs e parte para o proximo grupo. Termina quando todos
-- os K neuronios foram processados (K deve ser multiplo de 4).
entity accel_controller is
    Port (
        clk         : in  std_logic;
        reset       : in  std_logic;
        start       : in  std_logic;

        M           : in  std_logic_vector(15 downto 0);
        K           : in  std_logic_vector(15 downto 0);

        in_rd_addr  : out std_logic_vector(7 downto 0);
        w_rd_addr   : out std_logic_vector(7 downto 0);

        mac_clear   : out std_logic;
        mac_en      : out std_logic;

        acc0        : in  std_logic_vector(31 downto 0);
        acc1        : in  std_logic_vector(31 downto 0);
        acc2        : in  std_logic_vector(31 downto 0);
        acc3        : in  std_logic_vector(31 downto 0);

        out_we      : out std_logic;
        out_wr_addr : out std_logic_vector(5 downto 0);
        out_wr_data : out std_logic_vector(15 downto 0);

        busy        : out std_logic;
        done        : out std_logic;
        intr        : out std_logic
    );
end accel_controller;

architecture rtl of accel_controller is

    type state_t is (S_IDLE, S_LOAD, S_COMPUTE, S_STORE, S_DONE);
    signal state : state_t := S_IDLE;

    signal g_cnt     : unsigned(7 downto 0) := (others => '0');  -- indice do grupo
    signal k_cnt     : unsigned(7 downto 0) := (others => '0');  -- indice da entrada
    signal store_idx : unsigned(1 downto 0) := (others => '0');  -- 0..3 dentro do STORE

    signal M_u : unsigned(7 downto 0);
    signal G_u : unsigned(7 downto 0);  -- numero de grupos = K/4

    signal sel_acc      : std_logic_vector(31 downto 0);
    signal w_addr_calc  : unsigned(15 downto 0);

    signal done_reg : std_logic := '0';
    signal busy_reg : std_logic := '0';

    -- Saturacao 32 -> 16 bits signed
    function saturate_16(x : signed(31 downto 0)) return std_logic_vector is
        constant max16 : signed(31 downto 0) := to_signed(32767, 32);
        constant min16 : signed(31 downto 0) := to_signed(-32768, 32);
    begin
        if x > max16 then
            return std_logic_vector(to_signed(32767, 16));
        elsif x < min16 then
            return std_logic_vector(to_signed(-32768, 16));
        else
            return std_logic_vector(x(15 downto 0));
        end if;
    end function;

begin

    M_u <= unsigned(M(7 downto 0));
    G_u <= unsigned(K(9 downto 2));  -- K/4

    -- Mux do acumulador a ser armazenado neste passo de STORE
    with store_idx select
        sel_acc <= acc0 when "00",
                   acc1 when "01",
                   acc2 when "10",
                   acc3 when others;

    process(clk, reset)
    begin
        if reset = '1' then
            state     <= S_IDLE;
            g_cnt     <= (others => '0');
            k_cnt     <= (others => '0');
            store_idx <= (others => '0');
            mac_clear <= '0';
            mac_en    <= '0';
            out_we    <= '0';
            done_reg  <= '0';
            busy_reg  <= '0';

        elsif rising_edge(clk) then
            -- defaults sincronos (case body sobrepoe quando relevante)
            mac_clear <= '0';
            mac_en    <= '0';
            out_we    <= '0';

            case state is

                when S_IDLE =>
                    busy_reg <= '0';
                    if start = '1' then
                        g_cnt     <= (others => '0');
                        k_cnt     <= (others => '0');
                        store_idx <= (others => '0');
                        mac_clear <= '1';
                        done_reg  <= '0';
                        busy_reg  <= '1';
                        state     <= S_LOAD;
                    end if;

                when S_LOAD =>
                    -- Um ciclo para o pulso de clear chegar nas MACs
                    state <= S_COMPUTE;

                when S_COMPUTE =>
                    mac_en <= '1';
                    if k_cnt = M_u - 1 then
                        store_idx <= (others => '0');
                        state     <= S_STORE;
                    else
                        k_cnt <= k_cnt + 1;
                    end if;

                when S_STORE =>
                    out_we <= '1';
                    if store_idx = "11" then
                        if (g_cnt + 1) >= G_u then
                            state <= S_DONE;
                        else
                            g_cnt     <= g_cnt + 1;
                            k_cnt     <= (others => '0');
                            mac_clear <= '1';
                            state     <= S_LOAD;
                        end if;
                    else
                        store_idx <= store_idx + 1;
                    end if;

                when S_DONE =>
                    done_reg <= '1';
                    busy_reg <= '0';
                    state    <= S_IDLE;

            end case;
        end if;
    end process;

    -- Enderecos para os buffers durante COMPUTE
    -- input: x[k]
    -- weight: row = g*M + k (mesma row em todos os 4 bancos)
    in_rd_addr  <= std_logic_vector(k_cnt);
    w_addr_calc <= resize(g_cnt * M_u, 16) + resize(k_cnt, 16);
    w_rd_addr   <= std_logic_vector(w_addr_calc(7 downto 0));

    -- Endereco/dado para o output buffer (escrita serializada em 4 ciclos)
    out_wr_addr <= std_logic_vector(resize(g_cnt & "00", 6) or resize(store_idx, 6));
    out_wr_data <= saturate_16(signed(sel_acc));

    busy <= busy_reg;
    done <= done_reg;
    intr <= done_reg;  -- mantem alto ate o proximo start zerar done

end rtl;
